#!/usr/bin/env pwsh
# test_issue35_zoom_rerender.ps1
# Issue #35: zoom doesn't trigger re-render of the pane
# Fix: toggling resize-pane -Z re-renders so the zoomed pane fills the full area
# and window_zoomed_flag updates. Verified via dump-state layout.cols/rows expansion.

$ErrorActionPreference = 'Continue'
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "gap35"
$psmuxDir = "$env:USERPROFILE\.psmux"

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Step($msg) { Write-Host "`n[$(($script:TestsPassed + $script:TestsFailed + 1))] $msg" -ForegroundColor Cyan }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Get-DumpJson {
    $portFile = "$psmuxDir\$SESSION.port"
    $keyFile  = "$psmuxDir\$SESSION.key"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $portFile) -and $sw.ElapsedMilliseconds -lt 12000) { Start-Sleep -Milliseconds 300 }
    if (-not (Test-Path $portFile)) { return $null }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = (Get-Content $keyFile  -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$port)
    $tcp.NoDelay=$true; $tcp.ReceiveTimeout=10000
    $s=$tcp.GetStream()
    $w=[System.IO.StreamWriter]::new($s)
    $r=[System.IO.StreamReader]::new($s)
    $w.Write("AUTH $key`n"); $w.Flush(); $null=$r.ReadLine()
    $w.Write("PERSISTENT`n"); $w.Flush()
    $w.Write("dump-state`n"); $w.Flush()
    $best=$null; $tcp.ReceiveTimeout=3000
    for($i=0;$i -lt 80;$i++){
        try{$line=$r.ReadLine()}catch{break}
        if($null -eq $line){break}
        if($line.Length -gt 100){$best=$line}
        if($best){$tcp.ReceiveTimeout=300}
    }
    $tcp.Close()
    if ($best) { return $best | ConvertFrom-Json }
    return $null
}

# Helper: find leaf node with given pane id
function Find-Leaf {
    param($node, [int]$id)
    if ($node.type -eq "leaf" -and $node.id -eq $id) { return $node }
    if ($node.children) {
        foreach ($c in $node.children) {
            $r = Find-Leaf $c $id
            if ($r) { return $r }
        }
    }
    return $null
}

# === SETUP ===
Cleanup
Write-Host "`n=== Issue #35: zoom re-render (pane fills full area after zoom) ===" -ForegroundColor Cyan
& $PSMUX new-session -d -s $SESSION -x 220 -y 50 2>&1 | Out-Null
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Session creation failed" -ForegroundColor Red
    exit 1
}

# Split horizontally -> pane 0 (left) and pane 1 (right)
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

# Get pane IDs
$paneList = & $PSMUX list-panes -t $SESSION -F "#{pane_index}:#{pane_id}" 2>&1
$pane0Id = ($paneList | Where-Object { $_ -match '^0:' } | Select-Object -First 1) -replace '^0:%','' -replace '^0:',''
$pane1Id = ($paneList | Where-Object { $_ -match '^1:' } | Select-Object -First 1) -replace '^1:%','' -replace '^1:',''
Write-Host "  Pane IDs: pane0=$pane0Id  pane1=$pane1Id" -ForegroundColor DarkGray

# --- Test 1: before zoom, window_zoomed_flag = 0 ---
Write-Step "Before zoom: window_zoomed_flag = 0"
$flag = (& $PSMUX display-message -t $SESSION -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
if ($flag -eq "0") { Write-Pass "window_zoomed_flag=0 before zoom" }
else               { Write-Fail "Expected 0, got '$flag'" }

# --- Test 2: before zoom, both panes have partial cols (less than full width) ---
Write-Step "Before zoom: both panes have partial width (split layout)"
$dumpPre = Get-DumpJson
if (-not $dumpPre) { Write-Fail "No dump-state returned"; Cleanup; exit 1 }
$fullCols = 220
$fullRows = 50   # session created with -x 220 -y 50 (minus status bar = ~49)

# Find active pane cols from layout children
$leaf0 = $null; $leaf1 = $null
if ($pane0Id -match '^\d+$') {
    $leaf0 = Find-Leaf $dumpPre.layout ([int]$pane0Id)
    $leaf1 = Find-Leaf $dumpPre.layout ([int]$pane1Id)
}
if (-not $leaf0) {
    # Fallback: use layout children directly
    $leaf0 = $dumpPre.layout.children[0]
    $leaf1 = $dumpPre.layout.children[1]
}

$cols0Pre = [int]$leaf0.cols
$cols1Pre = [int]$leaf1.cols
Write-Host "  Pre-zoom: pane0.cols=$cols0Pre  pane1.cols=$cols1Pre  fullCols=$fullCols" -ForegroundColor DarkGray

if ($cols0Pre -lt ($fullCols - 5) -and $cols1Pre -lt ($fullCols - 5)) {
    Write-Pass "Both panes partial-width before zoom (pane0=$cols0Pre, pane1=$cols1Pre)"
} else {
    Write-Fail "Expected both panes < full width, got pane0=$cols0Pre pane1=$cols1Pre"
}

# --- Test 3: zoom pane 1 (non-first), window_zoomed_flag becomes 1 ---
Write-Step "After resize-pane -Z on pane 1: window_zoomed_flag = 1"
$target1 = "${SESSION}:.1"
& $PSMUX select-pane -t $target1 2>&1 | Out-Null
Start-Sleep -Milliseconds 300
& $PSMUX resize-pane -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$flag = (& $PSMUX display-message -t $SESSION -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
if ($flag -eq "1") { Write-Pass "window_zoomed_flag=1 after zoom" }
else               { Write-Fail "Expected 1, got '$flag' (BUG: zoom flag not updated)" }

# --- Test 4: dump-state shows zoomed=true ---
Write-Step "dump-state.zoomed = true after zoom"
$dumpZoom = Get-DumpJson
if (-not $dumpZoom) { Write-Fail "No dump-state returned"; Cleanup; exit 1 }
if ($dumpZoom.zoomed -eq $true) { Write-Pass "dump-state.zoomed=true" }
else                             { Write-Fail "dump-state.zoomed=$($dumpZoom.zoomed), expected true (BUG: re-render not triggered)" }

# --- Test 5: zoomed pane's cols expand to fill full area (re-render happened) ---
Write-Step "Zoomed pane cols expand to near-full width (re-render proof)"
$leaf0Z = $dumpZoom.layout.children[0]
$leaf1Z = $dumpZoom.layout.children[1]

# The active (zoomed) pane should be the one with ~full cols
# layout sizes are [0,100] style percentages; the zoomed pane gets 100%
$maxColsZ = [Math]::Max([int]$leaf0Z.cols, [int]$leaf1Z.cols)
$minColsZ = [Math]::Min([int]$leaf0Z.cols, [int]$leaf1Z.cols)
Write-Host "  Zoomed layout: child0.cols=$($leaf0Z.cols) child1.cols=$($leaf1Z.cols)" -ForegroundColor DarkGray

# The zoomed pane should be at least 3x the size it was before zoom, and close to fullCols
# (leave margin of ~10 for borders/status)
if ($maxColsZ -ge ($cols0Pre + $cols1Pre - 5)) {
    Write-Pass "Zoomed pane cols=$maxColsZ fills combined area (was max($cols0Pre,$cols1Pre), now $maxColsZ) - re-render confirmed"
} else {
    Write-Fail "BUG #35: Zoomed pane cols=$maxColsZ, expected ~$($cols0Pre + $cols1Pre). Pane did NOT expand (re-render missing)"
}

# The hidden pane must RETAIN its pre-zoom dimensions while the other pane is
# zoomed. This matches real tmux (hidden panes keep their layout size; only the
# zoomed pane temporarily takes the full window) and is load-bearing for
# issues #44/#45: the old behavior of shrinking hidden panes toward 0 columns
# resized their ConPTY + vt100 parser down to ~1-2 cols, reflowing and
# corrupting their buffers. The original near-0 assertion here encoded exactly
# that buffer-destroying behavior.
if ($minColsZ -ge ($cols0Pre - 5) -or $minColsZ -ge ($cols1Pre - 5)) {
    Write-Pass "Non-zoomed pane retained cols=$minColsZ during zoom (tmux parity; protects hidden-pane buffer per #44/#45)"
} else {
    Write-Fail "Non-zoomed pane cols=$minColsZ during zoom; expected it to RETAIN its pre-zoom width (~$cols0Pre/$cols1Pre)"
}

# --- Test 6: unzoom reverts both panes to split dimensions ---
Write-Step "After unzoom: panes revert to split dimensions"
& $PSMUX resize-pane -Z -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$dumpUnzoom = Get-DumpJson
$flagU = (& $PSMUX display-message -t $SESSION -p '#{window_zoomed_flag}' 2>&1 | Out-String).Trim()
if ($flagU -eq "0") { Write-Pass "window_zoomed_flag=0 after unzoom" }
else                { Write-Fail "Expected 0 after unzoom, got '$flagU'" }

$leaf0U = $dumpUnzoom.layout.children[0]
$leaf1U = $dumpUnzoom.layout.children[1]
$maxColsU = [Math]::Max([int]$leaf0U.cols, [int]$leaf1U.cols)
Write-Host "  Unzoomed: child0.cols=$($leaf0U.cols) child1.cols=$($leaf1U.cols)" -ForegroundColor DarkGray

if ($maxColsU -lt ($fullCols - 5)) {
    Write-Pass "Panes reverted to split width after unzoom (max=$maxColsU < fullCols=$fullCols)"
} else {
    Write-Fail "Panes did not revert after unzoom (max=$maxColsU, expected < $fullCols)"
}

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
if ($script:TestsFailed -eq 0) {
    Write-Host "`n  VERDICT: Issue #35 FIXED. Zoom triggers re-render; pane fills full area." -ForegroundColor Green
} else {
    Write-Host "`n  VERDICT: VERIFIED_BROKEN - zoom does not trigger re-render as expected." -ForegroundColor Red
}
exit $script:TestsFailed
