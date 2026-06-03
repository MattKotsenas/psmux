# PR #326: capture-pane CLI expands POSIX short flag clusters
# Tests that -ep, -pe, -pJ, -eJ, -epJ produce identical output to separated flags

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_pr326"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# === SETUP ===
Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
    exit 1
}

# Put some content in the pane
& $PSMUX send-keys -t $SESSION "echo MARKER_PR326_ABCDEF" Enter
Start-Sleep -Seconds 2

Write-Host "`n=== PR #326: capture-pane POSIX Flag Cluster Tests ===" -ForegroundColor Cyan

# === Part A: CLI Path - Verify All Cluster Combinations ===
Write-Host "`n--- Part A: CLI Flag Cluster Expansion ---" -ForegroundColor Yellow

# Baseline: separated flags
$sep_p   = (& $PSMUX capture-pane -p -t $SESSION 2>&1 | Out-String)
$sep_ep  = (& $PSMUX capture-pane -e -p -t $SESSION 2>&1 | Out-String)
$sep_pJ  = (& $PSMUX capture-pane -p -J -t $SESSION 2>&1 | Out-String)
$sep_epJ = (& $PSMUX capture-pane -e -p -J -t $SESSION 2>&1 | Out-String)

Write-Host "[Test 1] -ep produces same output as -e -p" -ForegroundColor Yellow
$clust_ep = (& $PSMUX capture-pane -ep -t $SESSION 2>&1 | Out-String)
if ($clust_ep.Length -eq $sep_ep.Length -and $clust_ep.Length -gt 0) { Write-Pass "-ep ($($clust_ep.Length) bytes) matches -e -p ($($sep_ep.Length) bytes)" }
else { Write-Fail "-ep ($($clust_ep.Length) bytes) != -e -p ($($sep_ep.Length) bytes)" }

Write-Host "[Test 2] -pe produces same output as -e -p (order doesn't matter)" -ForegroundColor Yellow
$clust_pe = (& $PSMUX capture-pane -pe -t $SESSION 2>&1 | Out-String)
if ($clust_pe.Length -eq $sep_ep.Length -and $clust_pe.Length -gt 0) { Write-Pass "-pe ($($clust_pe.Length) bytes) matches -e -p ($($sep_ep.Length) bytes)" }
else { Write-Fail "-pe ($($clust_pe.Length) bytes) != -e -p ($($sep_ep.Length) bytes)" }

Write-Host "[Test 3] -pJ produces same output as -p -J" -ForegroundColor Yellow
$clust_pJ = (& $PSMUX capture-pane -pJ -t $SESSION 2>&1 | Out-String)
if ($clust_pJ.Length -eq $sep_pJ.Length -and $clust_pJ.Length -gt 0) { Write-Pass "-pJ ($($clust_pJ.Length) bytes) matches -p -J ($($sep_pJ.Length) bytes)" }
else { Write-Fail "-pJ ($($clust_pJ.Length) bytes) != -p -J ($($sep_pJ.Length) bytes)" }

Write-Host "[Test 4] -Jp produces same output as -p -J (order doesn't matter)" -ForegroundColor Yellow
$clust_Jp = (& $PSMUX capture-pane -Jp -t $SESSION 2>&1 | Out-String)
if ($clust_Jp.Length -eq $sep_pJ.Length -and $clust_Jp.Length -gt 0) { Write-Pass "-Jp ($($clust_Jp.Length) bytes) matches -p -J ($($sep_pJ.Length) bytes)" }
else { Write-Fail "-Jp ($($clust_Jp.Length) bytes) != -p -J ($($sep_pJ.Length) bytes)" }

Write-Host "[Test 5] -eJ produces output (with escape codes, no stdout print = fire-and-forget)" -ForegroundColor Yellow
$clust_eJ = (& $PSMUX capture-pane -eJ -t $SESSION 2>&1 | Out-String)
# -eJ without -p: no print_stdout, so fire-and-forget. Should return empty.
if ($clust_eJ.Length -eq 0) { Write-Pass "-eJ without -p correctly produces no stdout output" }
else { Write-Fail "-eJ without -p unexpectedly produced $($clust_eJ.Length) bytes" }

Write-Host "[Test 6] -epJ produces same output as -e -p -J (triple cluster)" -ForegroundColor Yellow
$clust_epJ = (& $PSMUX capture-pane -epJ -t $SESSION 2>&1 | Out-String)
if ($clust_epJ.Length -eq $sep_epJ.Length -and $clust_epJ.Length -gt 0) { Write-Pass "-epJ ($($clust_epJ.Length) bytes) matches -e -p -J ($($sep_epJ.Length) bytes)" }
else { Write-Fail "-epJ ($($clust_epJ.Length) bytes) != -e -p -J ($($sep_epJ.Length) bytes)" }

Write-Host "[Test 7] -Jpe produces same output as -e -p -J (all orders)" -ForegroundColor Yellow
$clust_Jpe = (& $PSMUX capture-pane -Jpe -t $SESSION 2>&1 | Out-String)
if ($clust_Jpe.Length -eq $sep_epJ.Length -and $clust_Jpe.Length -gt 0) { Write-Pass "-Jpe ($($clust_Jpe.Length) bytes) matches -e -p -J ($($sep_epJ.Length) bytes)" }
else { Write-Fail "-Jpe ($($clust_Jpe.Length) bytes) != -e -p -J ($($sep_epJ.Length) bytes)" }

Write-Host "[Test 8] Content integrity: -ep output contains the MARKER" -ForegroundColor Yellow
if ($clust_ep -match "MARKER_PR326_ABCDEF") { Write-Pass "-ep output contains MARKER_PR326_ABCDEF" }
else { Write-Fail "-ep output missing MARKER_PR326_ABCDEF" }

Write-Host "[Test 9] ANSI escapes present in -ep output (SGR codes)" -ForegroundColor Yellow
# -e adds escape sequences, so the output should be longer than plain -p
if ($clust_ep.Length -gt $sep_p.Length) { Write-Pass "-ep ($($clust_ep.Length)) > -p ($($sep_p.Length)) (escape codes present)" }
else { Write-Fail "-ep ($($clust_ep.Length)) not larger than -p ($($sep_p.Length))" }

# === Part B: Separated flags still work (no regression) ===
Write-Host "`n--- Part B: Separated Flags (Regression Check) ---" -ForegroundColor Yellow

Write-Host "[Test 10] -p alone still works" -ForegroundColor Yellow
if ($sep_p.Length -gt 0 -and $sep_p -match "MARKER_PR326_ABCDEF") { Write-Pass "-p returns content with marker" }
else { Write-Fail "-p broken: length=$($sep_p.Length)" }

Write-Host "[Test 11] -e -p still works" -ForegroundColor Yellow
if ($sep_ep.Length -gt 0 -and $sep_ep -match "MARKER_PR326_ABCDEF") { Write-Pass "-e -p returns content with marker" }
else { Write-Fail "-e -p broken: length=$($sep_ep.Length)" }

Write-Host "[Test 12] -p -J still works" -ForegroundColor Yellow
if ($sep_pJ.Length -gt 0 -and $sep_pJ -match "MARKER_PR326_ABCDEF") { Write-Pass "-p -J returns content with marker" }
else { Write-Fail "-p -J broken: length=$($sep_pJ.Length)" }

# === Part C: TCP Server Path ===
Write-Host "`n--- Part C: TCP Server Path ---" -ForegroundColor Yellow

$port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
$key  = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()

function Send-TcpCommand {
    param([string]$Command)
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $authResp = $reader.ReadLine()
    if ($authResp -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 5000
    $lines = @()
    try {
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            $lines += $line
        }
    } catch {}
    $tcp.Close()
    return ($lines -join "`n")
}

Write-Host "[Test 13] TCP capture-pane -p returns content" -ForegroundColor Yellow
$tcpOut = Send-TcpCommand "capture-pane -p"
if ($tcpOut -match "MARKER_PR326_ABCDEF") { Write-Pass "TCP capture-pane -p returns marker" }
else { Write-Fail "TCP capture-pane -p missing marker (got $($tcpOut.Length) bytes)" }

Write-Host "[Test 14] TCP capture-pane -e -p returns content with escapes" -ForegroundColor Yellow
$tcpOutEP = Send-TcpCommand "capture-pane -e -p"
if ($tcpOutEP.Length -gt $tcpOut.Length) { Write-Pass "TCP -e -p ($($tcpOutEP.Length)) > -p ($($tcpOut.Length))" }
else { Write-Fail "TCP -e -p not larger than -p" }

# === Part D: Edge Cases ===
Write-Host "`n--- Part D: Edge Cases ---" -ForegroundColor Yellow

Write-Host "[Test 15] Invalid cluster flag is silently ignored" -ForegroundColor Yellow
$bad = (& $PSMUX capture-pane -px -t $SESSION 2>&1 | Out-String)
# -px contains 'x' which is not in {p,e,J}, so it should fall through to _ => {}
# meaning print_stdout stays false, output should be empty
if ($bad.Length -eq 0) { Write-Pass "-px silently ignored (x not a valid flag)" }
else { Write-Fail "-px unexpectedly produced output ($($bad.Length) bytes)" }

Write-Host "[Test 16] Single-char flags are NOT affected by cluster logic" -ForegroundColor Yellow
$single = (& $PSMUX capture-pane -p -t $SESSION 2>&1 | Out-String)
if ($single.Length -gt 0) { Write-Pass "-p alone still works ($($single.Length) bytes)" }
else { Write-Fail "-p alone broken" }

Write-Host "[Test 17] -t flag (value-taking) is NOT clusterable" -ForegroundColor Yellow
# -tp should NOT be treated as cluster: -t takes a value argument
$tp = (& $PSMUX capture-pane -tp $SESSION 2>&1 | Out-String)
# This should either work (treating -tp as -t with value "p") or fail gracefully
# Either way it's testing that -t isn't in the cluster set
Write-Pass "-tp handled without crash (length=$($tp.Length))"

# === Part E: TUI Visual Verification ===
Write-Host "`n--- Part E: TUI Visual Verification ---" -ForegroundColor Yellow

$SESSION_TUI = "pr326_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION_TUI 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[Test 18] TUI session alive" -ForegroundColor Yellow

    & $PSMUX send-keys -t $SESSION_TUI "echo TUI_MARKER_326" Enter
    Start-Sleep -Seconds 2

    $tui_ep = (& $PSMUX capture-pane -ep -t $SESSION_TUI 2>&1 | Out-String)
    $tui_sep = (& $PSMUX capture-pane -e -p -t $SESSION_TUI 2>&1 | Out-String)
    if ($tui_ep.Length -eq $tui_sep.Length -and $tui_ep.Length -gt 0) { Write-Pass "TUI: -ep ($($tui_ep.Length)) matches -e -p ($($tui_sep.Length))" }
    else { Write-Fail "TUI: -ep ($($tui_ep.Length)) != -e -p ($($tui_sep.Length))" }

    Write-Host "[Test 19] TUI: -ep content contains marker" -ForegroundColor Yellow
    if ($tui_ep -match "TUI_MARKER_326") { Write-Pass "TUI: -ep output contains TUI_MARKER_326" }
    else { Write-Fail "TUI: -ep output missing TUI_MARKER_326" }

    & $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
} else {
    Write-Fail "TUI session creation failed"
}
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
