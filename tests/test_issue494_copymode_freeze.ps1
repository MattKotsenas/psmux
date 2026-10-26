# Issue #494: copy-mode screen must freeze while new output arrives
# tmux: entering copy mode snapshots the view; new pane output keeps flowing
# into the buffer but the DISPLAYED content does not change until exit.
# Proof: run a fast counter in the pane, enter copy mode, snapshot the rendered
# rows (dump-state rows_v2) twice 3s apart. They must be identical while in
# copy mode, and must change again after leaving copy mode.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue494"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Get-DumpJson {
    param([string]$Name)
    $port = (Get-Content "$psmuxDir\$Name.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Name.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("PERSISTENT`n"); $writer.Flush()
    $writer.Write("dump-state`n"); $writer.Flush()
    $best = $null
    for ($j = 0; $j -lt 50; $j++) {
        try { $line = $reader.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best = $line }
        if ($best) { $tcp.ReceiveTimeout = 100 }
    }
    $tcp.Close()
    if ($best) { return $best | ConvertFrom-Json }
    return $null
}

function Get-RenderedText {
    param($json)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($row in $json.layout.rows_v2) {
        foreach ($run in $row.runs) { [void]$sb.Append($run.text) }
        [void]$sb.Append("`n")
    }
    return $sb.ToString()
}

# Setup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }
Start-Sleep -Seconds 2

Write-Host "`n=== Issue #494: copy-mode screen freeze ===" -ForegroundColor Cyan

# Start a fast counter producing continuous output
& $PSMUX send-keys -t $SESSION '1..100000 | ForEach-Object { Write-Host "COUNTER LINE $_"; Start-Sleep -Milliseconds 200 }' Enter
Start-Sleep -Seconds 3

# === TEST 1: output is flowing before copy mode (sanity) ===
Write-Host "`n[Test 1] Output flowing before copy mode" -ForegroundColor Yellow
$a = Get-RenderedText (Get-DumpJson $SESSION)
Start-Sleep -Seconds 3
$b = Get-RenderedText (Get-DumpJson $SESSION)
if ($a -ne $b) { Write-Pass "screen updates while NOT in copy mode" }
else { Write-Fail "setup problem: no output flowing" }

# === TEST 2: enter copy mode, screen must freeze ===
Write-Host "`n[Test 2] Screen frozen in copy mode" -ForegroundColor Yellow
& $PSMUX copy-mode -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 1
# First dump engages the freeze anchor; a visible empty cursor row may fill
# once right after (the anchor pins the scroll position, it does not snapshot
# cells). Take the baseline AFTER that settling dump.
$null = Get-DumpJson $SESSION
Start-Sleep -Seconds 1
$j1 = Get-DumpJson $SESSION
if (-not [bool]$j1.layout.copy_mode) { Write-Fail "copy-mode command did not enter copy mode" }
else {
    $s1 = Get-RenderedText $j1
    Start-Sleep -Seconds 4
    $j2 = Get-DumpJson $SESSION
    $s2 = Get-RenderedText $j2
    if (-not [bool]$j2.layout.copy_mode) { Write-Fail "copy mode exited by itself" }
    elseif ($s1 -eq $s2) { Write-Pass "rendered screen identical after 4s of new output (frozen)" }
    else {
        Write-Fail "BUG: rendered screen CHANGED while in copy mode"
        # show a hint of the diff
        $l1 = ($s1 -split "`n") | Where-Object { $_ -match "COUNTER LINE" } | Select-Object -Last 2
        $l2 = ($s2 -split "`n") | Where-Object { $_ -match "COUNTER LINE" } | Select-Object -Last 2
        Write-Host "  before: $($l1 -join ' | ')"
        Write-Host "  after:  $($l2 -join ' | ')"
    }
}

# === TEST 3: after exiting copy mode, screen updates again ===
Write-Host "`n[Test 3] Screen resumes after exiting copy mode" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION -X cancel 2>&1 | Out-Null
Start-Sleep -Seconds 1
$j3 = Get-DumpJson $SESSION
if ([bool]$j3.layout.copy_mode) { Write-Fail "send-keys -X cancel did not exit copy mode" }
else {
    $s3 = Get-RenderedText $j3
    Start-Sleep -Seconds 3
    $s4 = Get-RenderedText (Get-DumpJson $SESSION)
    if ($s3 -ne $s4) { Write-Pass "screen updates again after exiting copy mode" }
    else { Write-Fail "screen still frozen after exiting copy mode" }
}

# === TEARDOWN ===
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
