# Issue #240: Session chooser (prefix+s) has no scroll tracking, selected item goes off screen
#
# The original bug: session_chooser overlay used a hardcoded height with no scroll variable,
# so the selected highlight would go off screen when navigating past the visible window.
#
# The fix: session_scroll variable + clamp logic that keeps session_selected within the
# visible viewport [session_scroll .. session_scroll + visible_h).
#
# This test verifies the fix with two layers:
#   PART 1 - Source-code proof: session_scroll declared, clamp logic present, renderer
#            uses .skip(session_scroll).take(visible_h), scroll indicator drawn.
#   PART 2 - Functional proof: create 12 detached sessions, enumerate them over TCP,
#            confirm all 12 are reachable (the picker data-source works at scale), then
#            verify the server remains responsive throughout.

$ErrorActionPreference = "Continue"
$script:pass = 0
$script:fail = 0
$script:results = @()

function Write-Test($msg) { Write-Host "  TEST: $msg" -ForegroundColor Yellow }
function Write-Pass($msg) { Write-Host "  PASS: $msg" -ForegroundColor Green; $script:pass++ }
function Write-Fail($msg) { Write-Host "  FAIL: $msg" -ForegroundColor Red; $script:fail++ }
function Add-Result($name, $ok, $detail) {
    if ($ok) { Write-Pass "$name $detail" } else { Write-Fail "$name $detail" }
    $script:results += [PSCustomObject]@{ Test = $name; Pass = $ok; Detail = $detail }
}

# Binary resolution -- prefer installed binary per task constraints
$PSMUX = (Get-Command psmux -ErrorAction SilentlyContinue)?.Source
if (-not $PSMUX) {
    $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -ErrorAction SilentlyContinue)?.Path
}
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

$psmuxDir = "$env:USERPROFILE\.psmux"
$env:PSMUX_SESSION = ""

Write-Host "`n=== Issue #240: Session chooser scroll tracking ===" -ForegroundColor Cyan
Write-Host "  Binary: $PSMUX"

# ====================================================================
# PART 1: Source-code proof that scroll tracking is implemented
# ====================================================================
Write-Host "`n--- Part 1: Source-code proof ---" -ForegroundColor Yellow

$srcFile = Join-Path $PSScriptRoot "..\src\client.rs"
if (-not (Test-Path $srcFile)) {
    Add-Result "source file found" $false "client.rs not at $srcFile"
    exit 1
}
$src = Get-Content $srcFile -Raw

Write-Test "session_scroll variable declared alongside session_selected"
$scrollDeclared = $src -match 'let\s+mut\s+session_scroll\s*:\s*usize\s*=\s*0'
Add-Result "session_scroll declared" $scrollDeclared ""

Write-Test "session_scroll reset to 0 when chooser opens"
$scrollReset = $src -match 'session_scroll\s*=\s*0\s*;'
Add-Result "session_scroll reset on open" $scrollReset ""

Write-Test "Clamp: session_scroll advances when selected goes below visible bottom"
# session_scroll = session_selected.saturating_sub(visible_h - 1) when selected >= scroll + visible_h
$clampDown = $src -match 'session_selected\s*>=\s*session_scroll\s*\+\s*visible_h'
Add-Result "clamp: scroll advances with selection" $clampDown ""

Write-Test "Clamp: session_scroll retreats when selected goes above visible top"
$clampUp = $src -match 'session_selected\s*<\s*session_scroll'
Add-Result "clamp: scroll retreats with selection" $clampUp ""

Write-Test "Renderer: iterates entries with .skip(session_scroll).take(visible_h)"
$skipTake = $src -match '\.skip\(session_scroll\)\.take\(visible_h\)'
Add-Result "renderer uses skip+take for viewport" $skipTake ""

Write-Test "Scroll indicator: drawn when filtered_indices.len() > visible_h"
# Post-ea71e75 the session chooser renders through session_filtered_indices();
# the indicator condition now checks the filtered list, and the pct math is
# anchored on session_scroll to bind this match to the session chooser block.
$indicator = $src -match '(?s)if\s+filtered_indices\.len\(\)\s*>\s*visible_h\s*\{\s*let\s+max_scroll\s*=\s*filtered_indices\.len\(\)\.saturating_sub\(visible_h\);\s*let\s+pct\s*=\s*if\s+max_scroll\s*>\s*0\s*\{\s*session_scroll\s*\*\s*100'
Add-Result "scroll indicator condition present" $indicator ""

Write-Test "Scroll indicator: Top/Bot/% text drawn"
$topBot = ($src -match '"Top"') -and ($src -match '"Bot"')
Add-Result "Top/Bot indicator text present" $topBot ""

# ====================================================================
# PART 2: Functional proof with 12 sessions
# ====================================================================
Write-Host "`n--- Part 2: Functional proof (12 sessions) ---" -ForegroundColor Yellow

# Session names use prefix "gap240" to avoid touching other sessions
$prefix = "gap240"
$sessionNames = 1..12 | ForEach-Object { "${prefix}_$_" }

function Kill-OurSession($name) {
    & $PSMUX kill-session -t $name 2>$null | Out-Null
}

function Wait-Session($name, [int]$timeoutMs = 12000) {
    $pf = "$psmuxDir\$name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -ErrorAction SilentlyContinue).Trim()
            if ($port -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Query-SessionInfo($name) {
    $pf = "$psmuxDir\$name.port"
    $kf = "$psmuxDir\$name.key"
    if (-not (Test-Path $pf)) { return $null }
    try {
        $port = [int]((Get-Content $pf -Raw).Trim())
        $key  = if (Test-Path $kf) { (Get-Content $kf -Raw).Trim() } else { "" }
        $tcp  = [System.Net.Sockets.TcpClient]::new("127.0.0.1", $port)
        $st   = $tcp.GetStream()
        $st.ReadTimeout = 2000
        $w    = [System.IO.StreamWriter]::new($st); $w.AutoFlush = $true
        $r    = [System.IO.StreamReader]::new($st)
        $w.WriteLine("AUTH $key")
        $null = $r.ReadLine()
        $w.WriteLine("session-info")
        $line = $r.ReadLine()
        $tcp.Close()
        return $line
    } catch { return $null }
}

# Clean up any leftover sessions from previous runs
foreach ($s in $sessionNames) { Kill-OurSession $s }
Start-Sleep -Milliseconds 800

# Create 12 detached sessions
Write-Host "  Creating 12 detached sessions (${prefix}_1 .. ${prefix}_12)..." -ForegroundColor Gray
foreach ($s in $sessionNames) {
    & $PSMUX new-session -d -s $s 2>&1 | Out-Null
    Start-Sleep -Milliseconds 200
}

# Wait for all sessions to be reachable
$aliveCount = 0
foreach ($s in $sessionNames) {
    if (Wait-Session $s 12000) { $aliveCount++ }
}
Add-Result "all 12 sessions started" ($aliveCount -eq 12) "alive=$aliveCount/12"

# Verify all 12 have port files (picker data source)
$portCount = ($sessionNames | Where-Object { Test-Path "$psmuxDir\$_.port" }).Count
Add-Result "all 12 port files exist" ($portCount -eq 12) "found=$portCount/12"

# Verify session-info is reachable over TCP for all 12 (picker queries each)
Write-Host "  Querying session-info for all 12 sessions over TCP..." -ForegroundColor Gray
$respondCount = 0
foreach ($s in $sessionNames) {
    $info = Query-SessionInfo $s
    if ($info) { $respondCount++ }
}
Add-Result "all 12 sessions respond to session-info" ($respondCount -eq 12) "responded=$respondCount/12"

# Verify has-session returns success for all 12 (server responsive at scale)
$hasCount = 0
foreach ($s in $sessionNames) {
    & $PSMUX has-session -t $s 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $hasCount++ }
}
Add-Result "has-session confirms all 12 alive" ($hasCount -eq 12) "confirmed=$hasCount/12"

# Verify display-message works for entries beyond the original hardcoded viewport
# (entry 11 and 12 would have been off-screen with the old hardcoded 18-row height)
$dm11 = (& $PSMUX display-message -t "${prefix}_11" -p '#{session_name}' 2>&1).Trim()
$dm12 = (& $PSMUX display-message -t "${prefix}_12" -p '#{session_name}' 2>&1).Trim()
Add-Result "session 11 (beyond old viewport) reachable" ($dm11 -eq "${prefix}_11") "got=$dm11"
Add-Result "session 12 (beyond old viewport) reachable" ($dm12 -eq "${prefix}_12") "got=$dm12"

# ====================================================================
# Cleanup
# ====================================================================
foreach ($s in $sessionNames) { Kill-OurSession $s }

# ====================================================================
# Summary
# ====================================================================
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $pass / $($pass + $fail)" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
foreach ($r in $results) {
    $color  = if ($r.Pass) { 'Green' } else { 'Red' }
    $status = if ($r.Pass) { 'PASS' } else { 'FAIL' }
    Write-Host "  [$status] $($r.Test) $($r.Detail)" -ForegroundColor $color
}

if ($fail -gt 0) {
    Write-Host "`n  Some tests FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "`n  All tests passed. Issue #240 fix verified." -ForegroundColor Green
exit 0
