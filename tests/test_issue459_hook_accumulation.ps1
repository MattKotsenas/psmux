# Issue #459: runaway process spawn from unbounded hook accumulation.
#
# A config that registers `set-hook -ga status-interval 'run-shell "pwsh ..."'`
# (the psmux-cpu plugin shape) accumulated one duplicate handler per config
# reload. A plugin panel firing "Configuration reloaded" repeatedly drove the
# status-interval hook list to hundreds of identical copies; every status tick
# then fired all of them, spawning a runaway of pwsh.exe (reporter saw ~400).
#
# Fix: append (-a/-ga) now dedups an identical command already registered for a
# hook. This test proves: (1) N reloads no longer accumulate, (2) the process
# spawn stays bounded after many reloads, (3) DISTINCT handlers still append.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$S = "test_issue459"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }
function Cleanup { & $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 500; Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue }
function Count-Pwsh { (Get-Process pwsh -EA SilentlyContinue | Measure-Object).Count }

$tmp = "$env:TEMP\psmux_test_459"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# Slow stats script (3s) magnifies any spawn storm the way 100% CPU load would.
$statsScript = "$tmp\system_stats.ps1"
'Start-Sleep -Seconds 3' | Set-Content -Path $statsScript -Encoding UTF8

# psmux-cpu style config: status-interval hook that run-shells a pwsh script.
$conf = "$tmp\459.conf"
@"
set -g status-interval 1
set-hook -ga status-interval 'run-shell "pwsh -NoProfile -File \"$statsScript\""'
"@ | Set-Content -Path $conf -Encoding UTF8

Cleanup
$base = Count-Pwsh
$env:PSMUX_CONFIG_FILE = $conf
Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$S,"-d" -WindowStyle Hidden
Start-Sleep -Seconds 3
$env:PSMUX_CONFIG_FILE = $null
& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

Write-Host "`n=== Issue #459 Tests (baseline pwsh=$base) ===" -ForegroundColor Cyan

# Test 1: re-sourcing config must NOT accumulate duplicate hooks
Write-Host "`n[Test 1] 20 config reloads -> hook stays single copy" -ForegroundColor Yellow
for ($i=0;$i -lt 20;$i++){ & $PSMUX source-file -t $S $conf 2>&1 | Out-Null }
Start-Sleep -Milliseconds 500
$h = & $PSMUX show-hooks -t $S 2>&1 | Out-String
$copies = ([regex]::Matches($h,"status-interval")).Count
if ($copies -eq 1){ Write-Pass "status-interval hook = 1 copy after 20 reloads" }
else { Write-Fail "expected 1 copy, got $copies (accumulation bug)" }

# Test 2: process spawn stays bounded (no runaway) after the reloads
Write-Host "`n[Test 2] pwsh spawn stays bounded after reloads" -ForegroundColor Yellow
$maxPwsh = 0
for ($i=0;$i -lt 12;$i++){ Start-Sleep -Seconds 1; $p = Count-Pwsh; if ($p -gt $maxPwsh){$maxPwsh=$p} }
$delta = $maxPwsh - $base
Write-Host "  max pwsh=$maxPwsh (delta over baseline=$delta)"
# One handler + 3s script @ 1s tick = a handful in flight. Runaway bug produced 35+.
if ($delta -le 12){ Write-Pass "spawn bounded (delta $delta <= 12)" }
else { Write-Fail "runaway spawn: delta $delta processes" }

# Test 3: distinct handlers still append (multi-plugin semantics preserved)
Write-Host "`n[Test 3] distinct handlers still append" -ForegroundColor Yellow
& $PSMUX set-hook -ga status-interval 'run-shell "echo distinctB"' -t $S 2>&1 | Out-Null
& $PSMUX set-hook -ga status-interval 'run-shell "echo distinctC"' -t $S 2>&1 | Out-Null
$h2 = & $PSMUX show-hooks -t $S 2>&1 | Out-String
$total = ([regex]::Matches($h2,"status-interval")).Count
if ($total -eq 3 -and $h2 -match "distinctB" -and $h2 -match "distinctC"){ Write-Pass "3 distinct handlers coexist" }
else { Write-Fail "distinct append broken (total=$total)" }

Cleanup
Remove-Item $tmp -Recurse -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0){"Red"}else{"Green"})
exit $script:TestsFailed
