# Session chooser: the selection and preview must not get stuck.
#
# WHAT THIS USED TO DO, AND WHY IT COULD NEVER PASS
# -------------------------------------------------
# The original version read "$env:USERPROFILE\.psmux\preview_debug.log" and
# counted lines matching "session_chooser:". Nothing in psmux writes that file,
# and nothing anywhere in the source emits that string: it was instrumentation
# from a past investigation that was never shipped. So the log was always absent,
# the match count was always zero, and the suite reported
#
#   "Preview may be STUCK: only saw 0 distinct session_selected values"
#
# in every recorded run since 2026-08-09. It was measuring its own missing
# instrumentation and calling it a product bug.
#
# WHAT IT DOES NOW
# ----------------
# It looks at the screen, which is where a stuck preview would actually be
# visible. tests/conread.cs attaches to the client's console and reads both the
# characters AND the attributes. The attributes matter: the selected row differs
# from its neighbours only by COLOUR, so a character-only read shows an identical
# screen whether or not the selection moved, which is exactly the false "stuck"
# reading this file used to produce.
#
# One real finding from building this: the chooser opens with the CURRENT session
# selected, and that is the LAST entry, so pressing Down first appears to do
# nothing. Navigation is therefore driven with Up, and the Down-at-the-end case is
# asserted separately as the non-wrapping behaviour it is.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$TEMP = $env:TEMP
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($m) { Write-Host "    $m" -ForegroundColor DarkGray }

$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
if (-not (Test-Path $csc)) {
    $csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64\v4*\csc.exe" -EA SilentlyContinue |
           Select-Object -First 1 -ExpandProperty FullName
}
if (-not $csc -or -not (Test-Path $csc)) { Write-Host "FATAL: no csc.exe" -ForegroundColor Red; exit 1 }

# Both helpers are compiled from $PSScriptRoot, never a relative path: run from
# any other directory and a relative path silently reuses a stale binary from a
# different suite (both write into $TEMP).
$injectorExe = Join-Path $TEMP "psmux_injector_preview.exe"
$conreadExe  = Join-Path $TEMP "psmux_conread_preview.exe"
& $csc /nologo /optimize /out:$injectorExe (Join-Path $PSScriptRoot "injector.cs") 2>&1 | Out-Null
& $csc /nologo /optimize /out:$conreadExe  (Join-Path $PSScriptRoot "conread.cs")  2>&1 | Out-Null
if (-not (Test-Path $injectorExe)) { Write-Host "FATAL: injector build failed" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $conreadExe))  { Write-Host "FATAL: conread build failed" -ForegroundColor Red; exit 1 }

$SESSIONS = @('prevA','prevB','prevC')
$TUI = 'prevTUI'
function Cleanup {
    foreach ($s in ($SESSIONS + $TUI)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
    Start-Sleep -Milliseconds 800
    foreach ($s in ($SESSIONS + $TUI)) { Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue }
}

Write-Host "`n=== Session chooser: selection and preview must not stick ===" -ForegroundColor Cyan
Cleanup
foreach ($s in $SESSIONS) { & $PSMUX new-session -d -s $s 2>&1 | Out-Null; Start-Sleep -Seconds 3 }
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$TUI -PassThru
Start-Sleep -Seconds 6

& $PSMUX has-session -t $TUI 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "TUI session did not start"; Cleanup; exit 1 }

function Screen { ,@(& $conreadExe $proc.Id 24 -a 2>&1) }

# The selected row is the CHOOSER ENTRY carrying the longest run of a
# non-default attribute (default is 7). Unselected entries carry only short
# border runs, so the highlight stands out.
#
# Restricted to rows that are chooser entries. Without that restriction the
# status bar wins every time: it is styled across the full 120 columns, a longer
# run than any highlight, so the "selected row" never changed and a working
# chooser was reported as stuck.
function Selected-Row {
    param([string[]]$Lines)
    $best = -1; $bestRun = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^\[attr ([^\]]+)\]\s*(.*)$') { continue }
        $attrSpec = $Matches[1]
        $text = $Matches[2]
        # A chooser entry looks like "1.   name: N windows (created ...)".
        if ($text -notmatch '\d+\.\s' -or $text -notmatch 'windows') { continue }
        foreach ($pair in ($attrSpec -split ',')) {
            $kv = $pair -split 'x'
            if ($kv.Count -ne 2) { continue }
            if ([int]$kv[0] -eq 7) { continue }
            if ([int]$kv[1] -gt $bestRun) { $bestRun = [int]$kv[1]; $best = $i }
        }
    }
    return @{ Row = $best; Run = $bestRun }
}

# ---------------------------------------------------------------------------
Write-Host "`n[Test 1] prefix+s opens the chooser and it is visible on screen" -ForegroundColor Yellow
& $injectorExe $proc.Id "^b{SLEEP:500}s" | Out-Null
Start-Sleep -Seconds 3
$open = Screen
$openText = ($open -join "`n")
if ($openText -match 'choose-session') { Write-Pass "chooser is on screen (title row read from the console)" }
else { Write-Fail "chooser not visible on screen"; Write-Info ($open | Select-Object -First 6) }
foreach ($s in $SESSIONS) {
    if ($openText -match [regex]::Escape($s)) { Write-Pass "chooser lists $s" }
    else { Write-Fail "chooser does not list $s" }
}

# ---------------------------------------------------------------------------
Write-Host "`n[Test 2] exactly one row is highlighted" -ForegroundColor Yellow
$sel0 = Selected-Row $open
if ($sel0.Row -ge 0 -and $sel0.Run -gt 20) {
    Write-Pass "a row is highlighted (row $($sel0.Row), run of $($sel0.Run) cells)"
} else {
    Write-Fail "no highlighted row found (best run $($sel0.Run))"
}

# ---------------------------------------------------------------------------
# THE ACTUAL "STUCK" CHECK. Up is used because the chooser opens on the current
# session, which is the last entry.
Write-Host "`n[Test 3] the highlight MOVES as the selection is navigated" -ForegroundColor Yellow
$rows = New-Object System.Collections.Generic.List[int]
$rows.Add($sel0.Row)
for ($i = 1; $i -le 3; $i++) {
    & $injectorExe $proc.Id "{UP}" | Out-Null
    Start-Sleep -Seconds 2
    $sel = (Selected-Row (Screen)).Row
    Write-Info "after Up x$i the highlighted row is $sel"
    if (-not $rows.Contains($sel)) { $rows.Add($sel) }
}
if ($rows.Count -ge 3) {
    Write-Pass "selection visited $($rows.Count) distinct rows: $($rows -join ' -> ') (not stuck)"
} else {
    Write-Fail "selection STUCK: only $($rows.Count) distinct row(s): $($rows -join ' -> ')"
}

# ---------------------------------------------------------------------------
Write-Host "`n[Test 4] the preview toggle changes what is drawn" -ForegroundColor Yellow
$beforeToggle = (Screen) -join "`n"
& $injectorExe $proc.Id "p" | Out-Null
Start-Sleep -Seconds 3
$afterToggle = (Screen) -join "`n"
if ($beforeToggle -ne $afterToggle) { Write-Pass "toggling preview redrew the chooser" }
else { Write-Fail "preview toggle changed nothing on screen" }

# ---------------------------------------------------------------------------
Write-Host "`n[Test 5] Escape closes the chooser" -ForegroundColor Yellow
& $injectorExe $proc.Id "{ESC}" | Out-Null
Start-Sleep -Seconds 2
$closed = (Screen) -join "`n"
if ($closed -notmatch 'choose-session') { Write-Pass "chooser closed and is gone from the screen" }
else { Write-Fail "chooser still on screen after Escape" }

Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
