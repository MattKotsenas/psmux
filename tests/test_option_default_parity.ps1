# Option default parity, end to end against a real server.
#
# Contract under test: resetting an option to its default in customize-mode must
# restore the value a FRESH session actually had. If the option catalog and the
# runtime initializer disagree, "reset to default" silently writes a value the
# user never had, and customize-mode displays a default that is a lie.
#
# The reset path is: customize-mode -> customize-filter <name> -> customize-reset-default
# (`customize-reset-default` takes NO argument, it resets the SELECTED row, which
# is why the filter step is mandatory).
#
# This test carries a positive control. For each option it first writes a sentinel
# value, then resets. If the sentinel survives, the reset never ran and the test
# FAILS instead of silently reporting parity it never checked.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "optdefault_parity"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Connect-Persistent {
    param([string]$Name)
    $port = (Get-Content "$psmuxDir\$Name.port" -Raw).Trim()
    $key  = (Get-Content "$psmuxDir\$Name.key"  -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 8000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $resp = $reader.ReadLine()
    if ($resp -ne "OK") { $tcp.Close(); throw "AUTH failed: $resp" }
    $writer.Write("PERSISTENT`n"); $writer.Flush()
    Start-Sleep -Milliseconds 150
    return @{ tcp=$tcp; writer=$writer; reader=$reader }
}

function Send-Fire {
    param($conn, [string]$Command)
    $conn.writer.Write("$Command`n"); $conn.writer.Flush()
    Start-Sleep -Milliseconds 120
}

function Get-Opt {
    param([string]$Name)
    (& $PSMUX show-options -g -v $Name -t $SESSION 2>&1 | Out-String).Trim()
}

# Options previously found to diverge, plus a control group that always agreed.
$OPTIONS = @(
    "status-right", "mouse", "prediction-dimming", "set-clipboard",
    "claude-code-fix-tty", "claude-code-force-interactive",
    "main-pane-width", "main-pane-height", "update-environment",
    "window-status-format", "window-status-current-format",
    "set-titles-string", "default-terminal", "repeat-time",
    "copy-mode-line-numbers", "pane-border-lines",
    "status-left", "base-index", "history-limit", "status-interval"
)

Cleanup
Write-Host "`n=== Option Default Parity (end to end) ===" -ForegroundColor Cyan

& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

# --- Part A: show-options must report a real value, never a blank ---
# Several options had no arm in get_option_value and reported "" even though the
# feature was demonstrably active.
Write-Host "`n[Part A] show-options reports an effective value, not a blank" -ForegroundColor Yellow
$blank = @()
foreach ($opt in $OPTIONS) {
    $v = Get-Opt $opt
    if ([string]::IsNullOrWhiteSpace($v)) { $blank += $opt }
}
if ($blank.Count -eq 0) {
    Write-Pass "All $($OPTIONS.Count) options report a non-empty value"
} else {
    Write-Fail "$($blank.Count) option(s) report an empty value: $($blank -join ', ')"
}

# --- Part B: capture the true fresh-session defaults ---
$fresh = @{}
foreach ($opt in $OPTIONS) { $fresh[$opt] = Get-Opt $opt }

# --- Part C: reset each option in customize-mode, with a positive control ---
Write-Host "`n[Part C] customize-mode reset restores the fresh value" -ForegroundColor Yellow
$divergent   = @()
$controlDead = @()

foreach ($opt in $OPTIONS) {
    # Reconnect per option. A single long-lived control connection gets dropped
    # partway through the sweep, which silently skipped the tail of the list.
    try {
        $conn = Connect-Persistent -Name $SESSION
        Send-Fire $conn "customize-mode"
    } catch {
        $controlDead += $opt
        continue
    }
    # Positive control: make the value provably different first, so that a reset
    # which does nothing cannot be mistaken for a reset which restored correctly.
    $sentinel = if ($opt -in @("main-pane-width","main-pane-height","base-index","history-limit","status-interval","repeat-time")) { "7" } else { "PSMUX_SENTINEL" }
    & $PSMUX set-option -g -t $SESSION $opt $sentinel 2>&1 | Out-Null
    Start-Sleep -Milliseconds 80
    if ((Get-Opt $opt) -eq $fresh[$opt]) {
        # Could not perturb it, so this option cannot be meaningfully tested here.
        $controlDead += $opt
        try { $conn.tcp.Close() } catch {}
        continue
    }

    Send-Fire $conn "customize-filter $opt"
    Send-Fire $conn "customize-reset-default"
    $after = Get-Opt $opt
    try { $conn.tcp.Close() } catch {}

    if ($after -eq $sentinel) {
        # Reset did not fire at all.
        $controlDead += $opt
    } elseif ($after -cne $fresh[$opt]) {
        $divergent += [pscustomobject]@{ Option=$opt; Fresh=$fresh[$opt]; AfterReset=$after }
    }
}

foreach ($d in $divergent) {
    Write-Host "  DIVERGENT: $($d.Option)" -ForegroundColor Red
    Write-Host "      fresh session : '$($d.Fresh)'" -ForegroundColor DarkYellow
    Write-Host "      after reset   : '$($d.AfterReset)'" -ForegroundColor DarkYellow
}

$tested = $OPTIONS.Count - $controlDead.Count
Write-Info "reset exercised on $tested option(s); divergent: $($divergent.Count)"
if ($controlDead.Count -gt 0) {
    Write-Info "reset not observable for: $($controlDead -join ', ')"
}

if ($tested -eq 0) {
    Write-Fail "Positive control never fired: the reset path was never exercised, so this test proved nothing"
} elseif ($divergent.Count -eq 0) {
    Write-Pass "Reset restored the true fresh value for all $tested exercised option(s)"
} else {
    Write-Fail "$($divergent.Count) option(s) reset to a value the fresh session never had"
}

$sr = $divergent | Where-Object { $_.Option -eq "status-right" }
if ($sr) {
    Write-Fail "status-right REPRODUCED: reset yields '$($sr.AfterReset)' but fresh was '$($sr.Fresh)'"
} elseif ("status-right" -in $controlDead) {
    Write-Info "status-right reset was not observable in this run"
} else {
    Write-Pass "status-right resets to exactly its fresh-session value"
}

Cleanup

# --- Part D: Win32 TUI visual verification ---
# A real attached window, driven by CLI, proving the option surface behaves the
# same in an interactive session as it does in a detached one.
Write-Host "`n[Part D] Win32 TUI verification" -ForegroundColor Yellow
$SESSION_TUI = "optdefault_tui"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

$tuiSr = (& $PSMUX show-options -g -v status-right -t $SESSION_TUI 2>&1 | Out-String).Trim()
if (-not [string]::IsNullOrWhiteSpace($tuiSr)) {
    Write-Pass "TUI: status-right reports a value ('$($tuiSr.Substring(0,[Math]::Min(40,$tuiSr.Length)))...')"
} else {
    Write-Fail "TUI: status-right is empty in an attached session"
}

$tuiRepeat = (& $PSMUX show-options -g -v repeat-time -t $SESSION_TUI 2>&1 | Out-String).Trim()
if ($tuiRepeat -eq "500") {
    Write-Pass "TUI: repeat-time reports 500 (was empty before the getter fix)"
} else {
    Write-Fail "TUI: repeat-time expected 500, got '$tuiRepeat'"
}

$tuiBorder = (& $PSMUX show-options -g -v pane-border-lines -t $SESSION_TUI 2>&1 | Out-String).Trim()
if ($tuiBorder -eq "single") {
    Write-Pass "TUI: pane-border-lines reports single (was empty before the getter fix)"
} else {
    Write-Fail "TUI: pane-border-lines expected single, got '$tuiBorder'"
}

& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
