# Issue #482: pipe-pane strips every dash-flag token from the piped command.
# Before the fix, `pipe-pane -o "pwsh script.ps1 -EncodedCommand AAAA -NoProfile hello"`
# reached the child as `pwsh script.ps1 AAAA hello` (both dash-flags removed), so a
# `pwsh -NoProfile -EncodedCommand <b64>` sink could never start. This proves the
# command's own dash-flags now survive verbatim.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue482"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$tmp = Join-Path $env:TEMP "psmux_issue482"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$dumper = Join-Path $tmp "dump.ps1"
$argvOut = Join-Path $tmp "argv.txt"
'"ARGS:" + ($args -join "|") | Set-Content -Path "' + $argvOut + '"' | Set-Content -Path $dumper -Encoding UTF8

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}
Cleanup
Remove-Item $argvOut -Force -EA SilentlyContinue

& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX new-window -t $SESSION -n w pwsh -NoProfile -Command "Start-Sleep 300"
Start-Sleep -Seconds 8   # settle; piping right after new-window can miss the child

Write-Host "`n=== Issue #482: pipe-pane preserves command dash-flags ===" -ForegroundColor Cyan

# Sink: an argv dumper. The command carries its own dash-flags which must survive.
& $PSMUX pipe-pane -t "${SESSION}:1" -o "pwsh $dumper -EncodedCommand AAAA -NoProfile hello"
Start-Sleep -Seconds 1
& $PSMUX send-keys -t "${SESSION}:1" "echo trigger" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3

$argv = (Get-Content $argvOut -Raw -EA SilentlyContinue)
Write-Host "  child argv: $($argv.Trim())"
if ($argv -match "-EncodedCommand" -and $argv -match "-NoProfile") {
    Write-Pass "both -EncodedCommand and -NoProfile reached the child"
} else {
    Write-Fail "dash-flags stripped; got: $($argv.Trim())"
}
$expected = "ARGS:-EncodedCommand|AAAA|-NoProfile|hello"
if ($argv.Trim() -eq $expected) { Write-Pass "exact argv preserved: $expected" }
else { Write-Fail "argv mismatch. expected '$expected' got '$($argv.Trim())'" }

Cleanup
Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
Write-Host "`n=== Results: Passed=$($script:TestsPassed) Failed=$($script:TestsFailed) ===" -ForegroundColor Cyan
exit $script:TestsFailed
