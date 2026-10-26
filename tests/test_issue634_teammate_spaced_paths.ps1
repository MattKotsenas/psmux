# Issue #634: Claude Code agent teams inside psmux, project under a path with a
# space. Every teammate pane printed
#   &: The module 'Code' could not be loaded. For more information, run 'Import-Module Code'.
#
# Claude Code's TmuxBackend spawns a teammate with exactly one operand:
#   respawn-pane -k -t %N -- "cd '<cwd>' && env <VAR=val ...> '<claude>' <flags>"
# and it POSIX quotes every token that is not [A-Za-z0-9_./:=@+,-]+, so a
# forwarded environment value holding a space arrives single quoted.
# psmux's env-idiom parser cut the assignment run on plain whitespace, so
# `XDIR='D:\POC Code\todosample'` was read as `XDIR=` + `'D:\POC` plus an orphan
# `Code\todosample'`, and the orphan became the program of the `&` call psmux
# builds for the pane. PowerShell reads `Name\Command` as a module qualified
# invocation, which is where "the module 'Code'" came from.
#
# Arms:
#   1. the reporter's exact shape runs the real program (no module error)
#   2. the teammate binary itself under a spaced path is launched as one literal
#   3. the `cd` operand still lands the pane in the spaced directory
#   4. a quoted value keeps its spaces in the child's environment
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "t634e2e"
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$env:PSMUX_NO_WARM = "1"
$root = Join-Path $env:TEMP "psmux634\OneDrive - ACME INC\ADL\POC Code\todosample"
New-Item -ItemType Directory -Force -Path $root | Out-Null
# A "teammate binary" whose own path carries a space.
$spacedExe = Join-Path $root "my claude.exe"
Copy-Item -Force "$env:SystemRoot\System32\cmd.exe" $spacedExe

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session creation failed"; exit 1 }

Write-Host "`n=== Issue #634: teammate launch under paths with spaces ===" -ForegroundColor Cyan

function New-TeammatePane {
    $p = (& $PSMUX new-window -t $SESSION -P -F '#{pane_id}' -- cat 2>&1 | Out-String).Trim()
    Start-Sleep -Seconds 2
    & $PSMUX set-option -p -t $p remain-on-exit on 2>&1 | Out-Null
    return $p
}
function Get-PaneText([string]$pane) {
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 300
        $t = (& $PSMUX capture-pane -p -t $pane 2>&1 | Out-String).Trim()
        if ($t.Length -gt 0) { return $t }
    }
    return ""
}

# --- Arm 1: the reporter's exact shape ---
Write-Host "[Arm 1] quoted env value holding a space does not hijack the program" -ForegroundColor Yellow
$p1 = New-TeammatePane
$k1 = "cd '$root' && env CLAUDECODE=1 XDIR='D:\POC Code\todosample\.claude' '$env:SystemRoot\System32\cmd.exe' /c echo MARK634_ONE"
& $PSMUX respawn-pane -k -t $p1 -- $k1 2>&1 | Out-Null
$out1 = Get-PaneText $p1
if ($out1 -match "could not be loaded") {
    Write-Fail "the orphaned path tail was invoked: [$out1]"
} elseif ($out1 -match "MARK634_ONE") {
    Write-Pass "the real program ran (no module-qualified orphan call)"
} else {
    Write-Fail "unexpected pane content: [$out1]"
}
& $PSMUX kill-pane -t $p1 2>&1 | Out-Null

# --- Arm 2: the teammate binary's own path has a space ---
Write-Host "[Arm 2] quoted program path with a space stays one literal" -ForegroundColor Yellow
$p2 = New-TeammatePane
$k2 = "cd '$root' && env CLAUDECODE=1 '$spacedExe' /c echo MARK634_TWO"
& $PSMUX respawn-pane -k -t $p2 -- $k2 2>&1 | Out-Null
$out2 = Get-PaneText $p2
if ($out2 -match "MARK634_TWO") {
    Write-Pass "the spaced program path was invoked whole"
} else {
    Write-Fail "spaced program path was split: [$out2]"
}
& $PSMUX kill-pane -t $p2 2>&1 | Out-Null

# --- Arm 3: the cd operand still applies ---
Write-Host "[Arm 3] the cd target becomes the pane's working directory" -ForegroundColor Yellow
$p3 = New-TeammatePane
$k3 = "cd '$root' && env CLAUDECODE=1 '$env:SystemRoot\System32\cmd.exe' /c cd"
& $PSMUX respawn-pane -k -t $p3 -- $k3 2>&1 | Out-Null
$out3 = Get-PaneText $p3
if ($out3 -match "POC Code") {
    Write-Pass "the child started in the spaced directory"
} else {
    Write-Fail "the cd operand was lost: [$out3]"
}
& $PSMUX kill-pane -t $p3 2>&1 | Out-Null

# --- Arm 4: the quoted value reaches the child intact ---
Write-Host "[Arm 4] a quoted env value keeps its spaces in the child" -ForegroundColor Yellow
$p4 = New-TeammatePane
$k4 = "cd '$root' && env CLAUDECODE=1 XDIR='D:\POC Code\todosample' '$env:SystemRoot\System32\cmd.exe' /c echo [%XDIR%]"
& $PSMUX respawn-pane -k -t $p4 -- $k4 2>&1 | Out-Null
$out4 = Get-PaneText $p4
if ($out4 -match [regex]::Escape("[D:\POC Code\todosample]")) {
    Write-Pass "XDIR reached the child whole"
} else {
    Write-Fail "XDIR was truncated at the space: [$out4]"
}
& $PSMUX kill-pane -t $p4 2>&1 | Out-Null

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $spacedExe

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
