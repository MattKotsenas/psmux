# A detached `confirm-before kill-pane` answered with `send-keys y` closed
# the prompt and killed nothing, while `confirm-respond y` killed the pane:
# the send-keys answer ran the command through the config file parser,
# which has no arm for runtime commands. Each case opens the prompt on a
# detached session (no client), answers it, and counts panes.
#
# Isolation: a unique -L namespace per case, a private PSMUX_DATA_DIR and an
# empty config; cleanup only with `-L <ns> kill-server`. The default
# namespace is checked before and after.
#
#   pwsh -File tests\test_sendkeys_confirm.ps1 [-Exe <psmux.exe>] [-Mode default|shared|both]

param(
    [string]$Exe = $(if ($env:PSMUX_TEST_EXE) { $env:PSMUX_TEST_EXE } else { (Get-Command psmux -EA Stop).Source }),
    [ValidateSet("default", "shared", "both")][string]$Mode = "both"
)
$ErrorActionPreference = "Continue"
$script:Passed = 0; $script:Failed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Passed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failed++ }

$savedData = $env:PSMUX_DATA_DIR; $savedCfg = $env:PSMUX_CONFIG_FILE; $savedMode = $env:PSMUX_SERVER_MODE
Remove-Item Env:\PSMUX_DATA_DIR -EA SilentlyContinue
$defaultBefore = (& $Exe ls 2>&1 | Out-String).Trim()

$work = Join-Path $env:TEMP ("skc_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $work | Out-Null
$env:PSMUX_DATA_DIR = $work
$cfg = Join-Path $work "empty.conf"; "" | Set-Content $cfg
$env:PSMUX_CONFIG_FILE = $cfg

function P($ns) { $rest = $args; & $Exe -L $ns @rest 2>&1 }
function Panes($ns) { (P $ns display -p -t t '#{window_panes}' | Out-String).Trim() }
function PromptOpen($ns) { (P $ns dump-state -t t | Out-String) -match '"confirm_active":true' }

# Opens a three pane session, the prompt, answers it, returns the pane count.
function Run-Case([string]$guarded, [string[]]$confirmFlags, [scriptblock]$answer) {
    $ns = "skc" + [guid]::NewGuid().ToString('N').Substring(0, 6)
    P $ns new-session -d -s t | Out-Null
    Start-Sleep -Milliseconds 1500
    P $ns split-window -t t | Out-Null
    P $ns split-window -t t | Out-Null
    Start-Sleep -Milliseconds 600
    $before = Panes $ns
    P $ns confirm-before -t t @confirmFlags $guarded | Out-Null
    Start-Sleep -Milliseconds 400
    $opened = PromptOpen $ns
    & $answer $ns
    Start-Sleep -Milliseconds 900
    $r = [pscustomobject]@{ Before = $before; After = (Panes $ns); Opened = $opened; Closed = -not (PromptOpen $ns); Opt = (P $ns show -gqv '@skc' | Out-String).Trim() }
    P $ns kill-server | Out-Null
    return $r
}

$modes = if ($Mode -eq "both") { @("default", "shared") } else { @($Mode) }
try {
    foreach ($m in $modes) {
        if ($m -eq "shared") { $env:PSMUX_SERVER_MODE = "shared" } else { Remove-Item Env:\PSMUX_SERVER_MODE -EA SilentlyContinue }
        Write-Host "`n=== $m mode ===" -ForegroundColor Cyan

        $r = Run-Case "kill-pane" @() { param($ns) P $ns send-keys -t t y | Out-Null }
        if ($r.Opened -and $r.Closed -and $r.Before -eq "3" -and $r.After -eq "2") { Write-Pass "send-keys y runs kill-pane (3 -> 2)" }
        else { Write-Fail "send-keys y / kill-pane: panes $($r.Before) -> $($r.After), opened=$($r.Opened) closed=$($r.Closed)" }

        $r = Run-Case "split-window" @() { param($ns) P $ns send-keys -t t y | Out-Null }
        if ($r.Closed -and $r.Before -eq "3" -and $r.After -eq "4") { Write-Pass "send-keys y runs split-window (3 -> 4)" }
        else { Write-Fail "send-keys y / split-window: panes $($r.Before) -> $($r.After)" }

        $r = Run-Case "kill-pane" @("-y") { param($ns) P $ns send-keys -t t Enter | Out-Null }
        if ($r.Closed -and $r.After -eq "2") { Write-Pass "send-keys Enter with -y runs kill-pane (3 -> 2)" }
        else { Write-Fail "send-keys Enter -y / kill-pane: panes $($r.Before) -> $($r.After)" }

        $r = Run-Case "kill-pane" @() { param($ns) P $ns send-keys -t t n | Out-Null }
        if ($r.Closed -and $r.After -eq "3") { Write-Pass "send-keys n closes the prompt and kills nothing" }
        else { Write-Fail "send-keys n: panes $($r.Before) -> $($r.After), closed=$($r.Closed)" }

        $r = Run-Case "kill-pane" @() { param($ns) P $ns send-keys -t t Enter | Out-Null }
        if ($r.Closed -and $r.After -eq "3") { Write-Pass "send-keys Enter without -y kills nothing" }
        else { Write-Fail "send-keys Enter without -y: panes $($r.Before) -> $($r.After)" }

        $r = Run-Case "set -g @skc ran" @() { param($ns) P $ns send-keys -t t y | Out-Null }
        if ($r.Opt -eq "ran") { Write-Pass "send-keys y still runs a guarded set (@skc=ran)" }
        else { Write-Fail "send-keys y / set: @skc='$($r.Opt)'" }
    }
} finally {
    Remove-Item Env:\PSMUX_DATA_DIR -EA SilentlyContinue
    $defaultAfter = (& $Exe ls 2>&1 | Out-String).Trim()
    if ($defaultAfter -ne $defaultBefore) { Write-Fail "the default namespace changed: '$defaultBefore' -> '$defaultAfter'" }
    if ($null -ne $savedData) { $env:PSMUX_DATA_DIR = $savedData }
    if ($null -ne $savedCfg) { $env:PSMUX_CONFIG_FILE = $savedCfg } else { Remove-Item Env:\PSMUX_CONFIG_FILE -EA SilentlyContinue }
    if ($null -ne $savedMode) { $env:PSMUX_SERVER_MODE = $savedMode } else { Remove-Item Env:\PSMUX_SERVER_MODE -EA SilentlyContinue }
    Remove-Item -Recurse -Force $work -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Passed"
Write-Host "  Failed: $script:Failed"
exit $script:Failed
