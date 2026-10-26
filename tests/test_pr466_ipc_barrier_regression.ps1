# PR #466: session-info execution barrier on send_control.
# Targeted regression coverage BEYOND the PR's own test_command_reliability.ps1:
#   1. Command latency (the extra event-loop round-trip is the flagged tradeoff)
#   2. -L namespace kill-session (probe_session_alive hardcodes
#      {home}\.psmux\{session}.port; -L sessions are stored as <ns>__<session>)
#   3. Rapid mutate-then-inspect ordering (the race the barrier claims to close)
#
# Thresholds: a mutating one-shot command adds ONE round-trip. p90 under 350ms
# is acceptable for a loopback command; FAIL if it balloons.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Passed=0;$script:Failed=0
function Write-Pass($m){Write-Host "  [PASS] $m" -ForegroundColor Green;$script:Passed++}
function Write-Fail($m){Write-Host "  [FAIL] $m" -ForegroundColor Red;$script:Failed++}
function Metric($n,$v){Write-Host ("  [METRIC] {0}: {1:N1}ms" -f $n,$v) -ForegroundColor DarkCyan}
function Percentile($arr,$p){ if($arr.Count -eq 0){return 0}; $s=[double[]]($arr|Sort-Object); return $s[[Math]::Floor(($p/100.0)*($s.Count-1))] }

$S="pr466_reg"; $NS="pr466ns"; $NSS="nssess"
function Cleanup {
    & $PSMUX kill-session -t $S 2>&1 | Out-Null
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$S.*","$psmuxDir\${NS}__*" -Force -EA SilentlyContinue
}
Cleanup

Write-Host "`n=== PR #466: latency of mutating one-shot commands ===" -ForegroundColor Cyan
& $PSMUX new-session -d -s $S
Start-Sleep -Seconds 3
& $PSMUX has-session -t $S 2>$null
if($LASTEXITCODE -ne 0){Write-Fail "session create";Cleanup;exit 1}
Write-Pass "session created"

# set-option is a mutating command routed through send_control -> now barriered
# warmup (JIT + server accept path) so the measured loop reflects steady state
for($i=0;$i -lt 3;$i++){ & $PSMUX set-option -t $S history-limit 2000 2>&1 | Out-Null }
$times=[System.Collections.ArrayList]::new()
for($i=0;$i -lt 20;$i++){
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    & $PSMUX set-option -t $S history-limit (2000+$i) 2>&1 | Out-Null
    $sw.Stop()
    [void]$times.Add($sw.Elapsed.TotalMilliseconds)
}
$p50=Percentile $times 50; $p90=Percentile $times 90; $mx=($times|Measure-Object -Maximum).Maximum
Metric "set-option p50" $p50; Metric "set-option p90" $p90; Metric "set-option max" $mx
if($p90 -lt 350){Write-Pass "mutating command p90 under 350ms ($([math]::Round($p90,1))ms)"}
else{Write-Fail "mutating command p90 too slow: $([math]::Round($p90,1))ms (barrier overhead regression?)"}

# verify the last set-option actually applied (barrier => synchronous)
$hl=(& $PSMUX show-options -v -t $S history-limit 2>&1 | Out-String).Trim()
if($hl -eq "2019"){Write-Pass "mutate-then-read is race-free (history-limit=$hl)"}else{Write-Fail "expected 2019, got '$hl'"}

Write-Host "`n=== PR #466: rapid new-window burst then verify count ===" -ForegroundColor Cyan
for($i=0;$i -lt 5;$i++){ & $PSMUX new-window -t $S 2>&1 | Out-Null }
Start-Sleep -Milliseconds 500
$wins=(& $PSMUX display-message -t $S -p '#{session_windows}' 2>&1).Trim()
if([int]$wins -ge 6){Write-Pass "burst created windows (count=$wins)"}else{Write-Fail "expected >=6 windows, got $wins"}

Write-Host "`n=== PR #466: -L namespace kill-session (probe_session_alive path) ===" -ForegroundColor Cyan
& $PSMUX -L $NS new-session -d -s $NSS
Start-Sleep -Seconds 3
& $PSMUX -L $NS has-session -t $NSS 2>$null
if($LASTEXITCODE -eq 0){Write-Pass "-L namespace session created"}else{Write-Fail "-L session not created"}

$r = & $PSMUX -L $NS kill-session -t $NSS 2>&1
$code=$LASTEXITCODE
Start-Sleep -Milliseconds 800
& $PSMUX -L $NS has-session -t $NSS 2>$null
$gone=($LASTEXITCODE -ne 0)
if($code -eq 0 -and $gone){Write-Pass "-L kill-session exits 0 AND session actually gone"}
elseif($gone){Write-Fail "-L session gone but exit code was $code (barrier verify misjudged namespace path)"}
else{Write-Fail "-L kill-session did NOT remove session (exit=$code, out=$r)"}

# no raw socket-timeout leaked to the user on any command above
Write-Host "`n=== PR #466: no 'os error 100xx' leaked ===" -ForegroundColor Cyan
$probe = & $PSMUX ls 2>&1 | Out-String
if($probe -notmatch 'os error 100\d\d'){Write-Pass "ls output clean of socket-timeout errors"}else{Write-Fail "ls leaked socket error: $probe"}

Cleanup
Write-Host "`n=== PR #466 Results: Passed=$script:Passed Failed=$script:Failed ===" -ForegroundColor Cyan
exit $script:Failed
