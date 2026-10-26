# Issue #547: the one-shot CLI re-flattens argv to a text line quoting args
# and escaping ONLY double quotes, while the server unescapes both \" and \\.
# Every \\ collapses to \, and a value ending in \ re-reads as an escaped
# quote so the quote never closes and following flags/commands are swallowed.
# All at rc 0 with empty stderr.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$S = "t547"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue

Write-Host "`n=== Issue #547 repro ===" -ForegroundColor Cyan

& $PSMUX new-session -d -s $S -- pwsh -NoProfile -Command "Start-Sleep 600"
Start-Sleep -Seconds 3

function Check-Option {
    param([string]$Name, [string]$Value, [string]$Label)
    # Call psmux with a real argv list, no extra shell layer
    & $PSMUX set-option -g $Name $Value 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    Start-Sleep -Milliseconds 300
    $got = (& $PSMUX show-options -gqv $Name 2>&1 | Out-String).TrimEnd("`r","`n")
    if ($got -ceq $Value) { Write-Pass "$Label round-trips byte-exact" }
    else { Write-Fail "$Label sent [$Value] got [$got] (rc=$rc)" }
}

# Repro 3 from the issue: set-option value corruption
Check-Option "@a" '\\server\my share\file' "UNC path with space"
Check-Option "@b" 'a b\' "value with trailing backslash"
Check-Option "@c" 'a\\b c' "double backslash with space"
Check-Option "@d" 'a"b' "embedded double quote"
Check-Option "@e" "O'Brien" "embedded single quote"
Check-Option "@f" 'no_space\\path' "control: double backslash no whitespace"

# Repro 1: new-window -n mangles names and eats following flags
& $PSMUX new-window -d -t $S -n 'a\\b' -- pwsh -NoProfile -Command "Start-Sleep 300" 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $PSMUX new-window -d -t $S -n 'wname\' -c "$env:USERPROFILE\Documents" -- pwsh -NoProfile -Command "Start-Sleep 300" 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $PSMUX new-window -d -t $S -n 'a b\\c' -- pwsh -NoProfile -Command "Start-Sleep 300" 2>&1 | Out-Null
Start-Sleep -Seconds 1

$wins = (& $PSMUX list-windows -t $S -F '#{window_index}|#{window_name}' 2>&1)
$winsJoined = $wins -join ";"
Write-Host "  windows: $winsJoined"
if ($winsJoined -match [regex]::Escape('1|a\\b')) { Write-Pass "new-window -n 'a\\b' preserved" }
else { Write-Fail "new-window -n 'a\\b' mangled: $winsJoined" }
if ($winsJoined -match [regex]::Escape('2|wname\') -and $winsJoined -notmatch "wname`"") { Write-Pass "new-window -n 'wname\' preserved, flags not swallowed" }
else { Write-Fail "new-window -n 'wname\' mangled: $winsJoined" }
if ($winsJoined -match [regex]::Escape('3|a b\\c')) { Write-Pass "new-window -n 'a b\\c' preserved" }
else { Write-Fail "new-window -n 'a b\\c' mangled: $winsJoined" }

# Repro 2: new-window from a drive root (start dir C:\ has trailing backslash)
Push-Location "C:\"
& $PSMUX new-window -d -t $S -P -F '#{window_index}' -- pwsh -NoProfile -Command "Start-Sleep 300" 2>&1 | Out-Null
Pop-Location
Start-Sleep -Seconds 2
$last = (& $PSMUX list-windows -t $S -F '#{window_index}|#{window_name}|#{pane_current_path}' 2>&1 | Select-Object -Last 1)
Write-Host "  drive-root window: $last"
if ($last -match '\|C:\\$') { Write-Pass "new-window from C:\ starts in C:\" }
else { Write-Fail "new-window from C:\ wrong dir: $last" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
