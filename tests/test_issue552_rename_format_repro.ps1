# Issue #552: rename-window stores its argument literally instead of
# expanding it as a format. display-message expands the identical format, so
# the engine supports it; rename-window just never calls it.
# tmux parity: cmd-rename-window.c runs the argument through
# format_single_from_target.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "t552"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #552 repro ===" -ForegroundColor Cyan

& $PSMUX new-session -d -s $S -n w0 -- pwsh -NoProfile -Command "Start-Sleep 600"
Start-Sleep -Seconds 3
& $PSMUX new-window -d -t $S -n w1 -- pwsh -NoProfile -Command "Start-Sleep 600"
Start-Sleep -Seconds 2

# Literal rename still works
& $PSMUX rename-window -t "${S}:1" 'XX beta' 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$n = ((& $PSMUX list-windows -t $S -F '#{window_index}=#{window_name}' 2>&1) -join ";")
if ($n -match "1=XX beta") { Write-Pass "literal rename works (1=XX beta)" }
else { Write-Fail "literal rename broken: $n" }

# Control: the format engine expands this fine under display-message
$dm = (& $PSMUX display-message -p -t "${S}:1" '#{s/^XX //:window_name}' 2>&1 | Out-String).Trim()
if ($dm -eq "beta") { Write-Pass "control: display-message expands s/^XX // to '$dm'" }
else { Write-Fail "control: display-message expansion got '$dm' (expected beta)" }

# BUG: rename-window with the same format stores it verbatim
& $PSMUX rename-window -t "${S}:1" '#{s/^XX //:window_name}' 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$n = ((& $PSMUX list-windows -t $S -F '#{window_index}=#{window_name}' 2>&1) -join ";")
if ($n -match "1=beta") { Write-Pass "rename-window expands format (1=beta)" }
elseif ($n -match [regex]::Escape('1=#{s/^XX //:window_name}')) { Write-Fail "BUG: rename-window stored the format literally: $n" }
else { Write-Fail "unexpected window list: $n" }

# tmux idiom: window name from a variable
& $PSMUX rename-window -t "${S}:0" '#{session_name}-win' 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$n = ((& $PSMUX list-windows -t $S -F '#{window_index}=#{window_name}' 2>&1) -join ";")
if ($n -match "0=$S-win") { Write-Pass "rename-window expands #{session_name} (0=$S-win)" }
else { Write-Fail "rename-window #{session_name} not expanded: $n" }

# Plain names with no format chars must be untouched (hash-free fast path)
& $PSMUX rename-window -t "${S}:0" 'plain name' 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$n = ((& $PSMUX list-windows -t $S -F '#{window_index}=#{window_name}' 2>&1) -join ";")
if ($n -match "0=plain name") { Write-Pass "plain rename untouched (0=plain name)" }
else { Write-Fail "plain rename broken: $n" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
