# Issue #638: Ctrl+C at an idle shell inside Neovim `:terminal` killed Neovim.
#
# Mechanism (reproduced with a physical Ctrl+C injected via WriteConsoleInput
# into a real attached psmux client, fatal 3 of 3 runs on the unfixed binary,
# with both `cmd.exe` and `pwsh` as Neovim's `&shell`):
#
#   ctrl_c: console process list n=4 members=[3628=pmux.exe | 8636=nvim.exe |
#           21068=nvim.exe | 11276=pwsh.exe]
#   ctrl_c: console mode=0x0208 PROCESSED_INPUT=false fg_is_shell=true
#   ctrl_c: GenerateConsoleCtrlEvent => ok=1 err=183
#   pane   -> Nvim: Caught deadly signal 'SIGINT'
#
# The Ctrl+C router classifies the pane's foreground by walking the PPID tree
# to its deepest leaf.  With `:terminal` open that leaf is the inner shell,
# which Neovim runs on its OWN pseudoconsole: a PPID descendant of the pane, so
# the walk finds it and `fg_is_shell` is true, but not a member of the pane
# console, so the console-wide broadcast can never be delivered to it.  What
# the broadcast does reach is everything that IS on the pane console, Neovim
# included, and Neovim's default handler terminates it.
#
# Fix: fire the console control event only when the process that justified it
# is a member of the console that receives it; otherwise write the raw 0x03
# byte, which is all tmux ever delivers on Unix.
#
# Arms 1 and 2 fail on the unfixed binary and pass on the fixed one.  Arms 3
# and 4 are the load-bearing controls that must be unchanged by the fix:
# interrupting a real command inside `:terminal`, and the bare shell prompt
# line-cancel of #338 whose broadcast must still fire.

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:TestsFailed++ }

$nvimCmd = Get-Command nvim -EA SilentlyContinue
if (-not $nvimCmd) { Write-Host "SKIP: Neovim not installed" -ForegroundColor Yellow; exit 0 }

$INJ = "$env:TEMP\psmux_injector638.exe"
if (-not (Test-Path $INJ)) {
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $src = Join-Path $PSScriptRoot "injector.cs"
    if (Test-Path $csc) { & $csc /nologo /optimize /out:$INJ $src 2>&1 | Out-Null }
}
if (-not (Test-Path $INJ)) { Write-Host "SKIP: injector compile failed" -ForegroundColor Yellow; exit 0 }

$NS  = "t638"
$LOG = "$env:USERPROFILE\.psmux\mouse_debug.log"
$env:PSMUX_NO_WARM = "1"
$env:PSMUX_MOUSE_DEBUG = "1"
Remove-Item Env:NO_COLOR -EA SilentlyContinue
Remove-Item Env:PSMUX_SESSION_NAME -EA SilentlyContinue

function P { & $PSMUX -L $NS @args 2>&1 }
function Cap([string]$S) { (P capture-pane -t $S -p) -join "`n" }

function Wait-For([string]$S, [string]$pat, [int]$tries = 60) {
    for ($i = 0; $i -lt $tries; $i++) {
        Start-Sleep -Milliseconds 300
        if ((Cap $S) -match $pat) { return $true }
    }
    return $false
}

# Launch an attached client (its own console window) and open nvim + :terminal
# in it.  Returns the client process, the nvim PIDs it created, or $null.
function Start-NvimTerminalPane([string]$S, [string]$InnerShell) {
    P kill-session -t $S | Out-Null
    Start-Sleep -Milliseconds 400
    if (Test-Path $LOG) { Remove-Item $LOG -Force -EA SilentlyContinue }
    $before = @(Get-Process nvim -EA SilentlyContinue | Select-Object -Expand Id)
    $client = Start-Process -FilePath $PSMUX -ArgumentList @("-L",$NS,"new-session","-s",$S) -PassThru
    if (-not (Wait-For $S '>\s*$|\$\s*$')) { return @{ Client = $client; Nvim = @(); Ok = $false } }
    P send-keys -t $S "nvim --clean" Enter | Out-Null
    if (-not (Wait-For $S 'NVIM|\[No Name\]')) { return @{ Client = $client; Nvim = @(); Ok = $false } }
    Start-Sleep -Milliseconds 800
    P send-keys -t $S ":set shell=$InnerShell" Enter | Out-Null
    Start-Sleep -Milliseconds 500
    P send-keys -t $S ":terminal" Enter | Out-Null
    if (-not (Wait-For $S '>')) { return @{ Client = $client; Nvim = @(); Ok = $false } }
    Start-Sleep -Milliseconds 1500
    P send-keys -t $S "i" | Out-Null   # TERMINAL mode, the reporter's state
    Start-Sleep -Milliseconds 800
    $nv = @(Get-Process nvim -EA SilentlyContinue | Select-Object -Expand Id |
            Where-Object { $before -notcontains $_ })
    return @{ Client = $client; Nvim = $nv; Ok = ($nv.Count -gt 0) }
}

function Stop-Pane([string]$S, $pane) {
    foreach ($id in $pane.Nvim) { Stop-Process -Id $id -Force -EA SilentlyContinue }
    P kill-session -t $S | Out-Null
    Start-Sleep -Milliseconds 300
    if ($pane.Client) { Stop-Process -Id $pane.Client.Id -Force -EA SilentlyContinue }
}

function Get-Trace { if (Test-Path $LOG) { (Get-Content $LOG | Select-String 'ctrl_c') -join "`n" } else { "" } }

Write-Host "`n=== Issue #638: Ctrl+C inside Neovim :terminal must not signal Neovim ===" -ForegroundColor Cyan
Write-Host "  binary: $PSMUX" -ForegroundColor DarkGray

# --- Arm 1: idle prompt inside :terminal, cmd.exe (the reporter's &shell) ----
Write-Host "[Arm 1] nvim :terminal + cmd.exe, idle prompt, physical Ctrl+C" -ForegroundColor Yellow
$S = "t638a"
$pane = Start-NvimTerminalPane $S "cmd.exe"
if (-not $pane.Ok) {
    Write-Fail "Arm 1: could not bring up nvim :terminal"
} else {
    & $INJ $pane.Client.Id "^c"
    Start-Sleep -Seconds 3
    $alive = @($pane.Nvim | Where-Object { Get-Process -Id $_ -EA SilentlyContinue })
    $cap = Cap $S
    $trace = Get-Trace

    if ($alive.Count -eq $pane.Nvim.Count) {
        Write-Pass "Arm 1: all $($pane.Nvim.Count) nvim processes survived Ctrl+C"
    } else {
        Write-Fail "Arm 1: nvim died ($($pane.Nvim.Count) before, $($alive.Count) after)"
    }
    if ($cap -notmatch "deadly signal") {
        Write-Pass "Arm 1: no 'Caught deadly signal' in the pane"
    } else {
        Write-Fail "Arm 1: pane shows 'Nvim: Caught deadly signal'"
    }
    if ($trace -notmatch "GenerateConsoleCtrlEvent") {
        Write-Pass "Arm 1: no CTRL_C_EVENT broadcast fired"
    } else {
        Write-Fail "Arm 1: GenerateConsoleCtrlEvent fired with nvim on the console"
    }
    if ($trace -match "not on the pane console") {
        Write-Pass "Arm 1: the console-membership rule fired and named the leaf"
    } else {
        Write-Fail "Arm 1: the console-membership rule did not fire`n$trace"
    }
    # The interrupt must still DO something: a fresh prompt line appears.
    $prompts = ([regex]::Matches($cap, '(?m)^[A-Za-z]:\\.*>\s*$')).Count
    if ($prompts -ge 2) {
        Write-Pass "Arm 1: Ctrl+C cancelled the idle line (fresh prompt, $prompts seen)"
    } else {
        Write-Fail "Arm 1: no fresh prompt after Ctrl+C ($prompts seen)"
    }
}
Stop-Pane $S $pane

# --- Arm 2: same, with pwsh as Neovim's &shell ------------------------------
Write-Host "[Arm 2] nvim :terminal + pwsh, idle prompt, physical Ctrl+C" -ForegroundColor Yellow
$S = "t638b"
$pane = Start-NvimTerminalPane $S "pwsh"
if (-not $pane.Ok) {
    Write-Fail "Arm 2: could not bring up nvim :terminal"
} else {
    & $INJ $pane.Client.Id "^c"
    Start-Sleep -Seconds 3
    $alive = @($pane.Nvim | Where-Object { Get-Process -Id $_ -EA SilentlyContinue })
    $trace = Get-Trace

    if ($alive.Count -eq $pane.Nvim.Count) {
        Write-Pass "Arm 2: all $($pane.Nvim.Count) nvim processes survived Ctrl+C"
    } else {
        Write-Fail "Arm 2: nvim died ($($pane.Nvim.Count) before, $($alive.Count) after)"
    }
    if ($trace -notmatch "GenerateConsoleCtrlEvent") {
        Write-Pass "Arm 2: no CTRL_C_EVENT broadcast fired"
    } else {
        Write-Fail "Arm 2: GenerateConsoleCtrlEvent fired with nvim on the console"
    }
}
Stop-Pane $S $pane

# --- Arm 3 (control): a real command inside :terminal is still interrupted ---
Write-Host "[Arm 3] control: ping inside :terminal, Ctrl+C interrupts it" -ForegroundColor Yellow
$S = "t638c"
$pane = Start-NvimTerminalPane $S "cmd.exe"
if (-not $pane.Ok) {
    Write-Fail "Arm 3: could not bring up nvim :terminal"
} else {
    P send-keys -t $S "ping localhost -t" Enter | Out-Null
    if (Wait-For $S 'Reply from|bytes of data') {
        & $INJ $pane.Client.Id "^c"
        Start-Sleep -Seconds 3
        $cap = Cap $S
        $alive = @($pane.Nvim | Where-Object { Get-Process -Id $_ -EA SilentlyContinue })
        if ($cap -match "Ping statistics|Control-C") {
            Write-Pass "Arm 3: ping was interrupted"
        } else {
            Write-Fail "Arm 3: ping kept running after Ctrl+C"
        }
        if ($alive.Count -eq $pane.Nvim.Count) {
            Write-Pass "Arm 3: nvim survived the interrupt"
        } else {
            Write-Fail "Arm 3: nvim died while interrupting ping"
        }
    } else {
        Write-Fail "Arm 3: ping never started inside :terminal"
    }
}
Stop-Pane $S $pane

# --- Arm 4 (control, #338): bare shell prompt still gets the broadcast -------
Write-Host "[Arm 4] control (#338): bare pane shell, Ctrl+C still broadcasts" -ForegroundColor Yellow
$S = "t638d"
P kill-session -t $S | Out-Null
Start-Sleep -Milliseconds 400
if (Test-Path $LOG) { Remove-Item $LOG -Force -EA SilentlyContinue }
$client4 = Start-Process -FilePath $PSMUX -ArgumentList @("-L",$NS,"new-session","-s",$S) -PassThru
if (-not (Wait-For $S '>\s*$|\$\s*$')) {
    Write-Fail "Arm 4: pane shell never reached a prompt"
} else {
    Start-Sleep -Milliseconds 800
    & $INJ $client4.Id "^c"
    Start-Sleep -Seconds 2
    $trace = Get-Trace
    $cap = Cap $S
    if ($trace -match "GenerateConsoleCtrlEvent => ok=1") {
        Write-Pass "Arm 4: the #338 line-cancel broadcast still fires at a bare prompt"
    } else {
        Write-Fail "Arm 4: the bare-prompt broadcast was suppressed`n$trace"
    }
    if ($trace -notmatch "not on the pane console") {
        Write-Pass "Arm 4: the #638 rule did not misfire on a bare shell"
    } else {
        Write-Fail "Arm 4: the #638 rule wrongly refused a bare shell broadcast"
    }
    if ($cap -match '\^C') {
        Write-Pass "Arm 4: the shell echoed the cancelled line"
    } else {
        Write-Fail "Arm 4: no line cancel visible in the pane"
    }
}
P kill-session -t $S | Out-Null
Start-Sleep -Milliseconds 300
Stop-Process -Id $client4.Id -Force -EA SilentlyContinue

# --- teardown ---------------------------------------------------------------
P kill-server | Out-Null

Write-Host "`n=== Results: $script:TestsPassed passed, $script:TestsFailed failed ===" -ForegroundColor Cyan
exit $script:TestsFailed
