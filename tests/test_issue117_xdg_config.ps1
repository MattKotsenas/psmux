# test_issue117_xdg_config.ps1
# Verify psmux loads config from ~/.config/psmux/psmux.conf (XDG-style path)
# https://github.com/psmux/psmux/issues/117
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_issue117_xdg_config.ps1

$ErrorActionPreference = "Continue"
# This suite writes a config at a default path (~/.psmux.conf, ~/.tmux.conf or
# ~/.config/psmux) and expects psmux to load it at startup, but PSMUX_CONFIG_FILE
# replaces every default path and a developer's shell may have it set, so clear it (#748).
Remove-Item Env:PSMUX_CONFIG_FILE -ErrorAction SilentlyContinue
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red;   $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }
function Write-Test($msg) { Write-Host "  [TEST] $msg" -ForegroundColor White }

$PSMUX = (Get-Command psmux -ErrorAction Stop).Source
Write-Info "Binary: $PSMUX"

$psmuxDir   = "$env:USERPROFILE\.psmux"
$SESSION    = "gap117_$(Get-Random)"
$XDG_DIR    = "$env:USERPROFILE\.config\psmux"
$XDG_CONF   = "$XDG_DIR\psmux.conf"
$MARKER     = "XDG117LOADED"

# --- helpers ---
function Wait-Session {
    param([string]$Name, [int]$TimeoutMs = 12000)
    $pf = "$psmuxDir\$Name.port"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (Test-Path $pf) {
            $port = (Get-Content $pf -Raw -ErrorAction SilentlyContinue)
            if ($port -and $port.Trim() -match '^\d+$') {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port.Trim())
                    $tcp.Close()
                    return $true
                } catch {}
            }
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -ErrorAction SilentlyContinue
    # Remove only the XDG config we created
    if (Test-Path $XDG_CONF) { Remove-Item $XDG_CONF -Force -ErrorAction SilentlyContinue }
    # Remove dir only if we created it and it is empty
    if (Test-Path $XDG_DIR) {
        $remaining = Get-ChildItem $XDG_DIR -ErrorAction SilentlyContinue
        if (-not $remaining) { Remove-Item $XDG_DIR -Force -ErrorAction SilentlyContinue }
    }
}

# --- guard: ensure no leftover session from a previous run ---
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

# --- record whether the XDG config dir/file pre-existed so we can restore ---
$xdgDirPreExisted  = Test-Path $XDG_DIR
$xdgConfPreExisted = Test-Path $XDG_CONF
$xdgConfBackup     = $null
if ($xdgConfPreExisted) {
    $xdgConfBackup = "$env:TEMP\psmux_117_conf_backup_$(Get-Random)"
    Copy-Item $XDG_CONF $xdgConfBackup -Force
    Write-Info "Backed up pre-existing XDG config: $XDG_CONF -> $xdgConfBackup"
}

# =============================================================================
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Magenta
Write-Host "  ISSUE #117: Config loaded from ~/.config/psmux/psmux.conf" -ForegroundColor Magenta
Write-Host ("=" * 70) -ForegroundColor Magenta

# --- Create the XDG config directory and file ---
Write-Test "Creating XDG config at $XDG_CONF"
New-Item -Path $XDG_DIR -ItemType Directory -Force | Out-Null
@"
# Issue #117 test config - XDG path
set -g status-right "$MARKER"
"@ | Set-Content -Path $XDG_CONF -Encoding UTF8 -NoNewline
Write-Info "XDG config written"

# --- Also ensure no classic config exists that would shadow our XDG one ---
$classicCandidates = @(
    "$env:USERPROFILE\.psmux.conf",
    "$env:USERPROFILE\.psmuxrc",
    "$env:USERPROFILE\.tmux.conf"
)
$classicBackups = @{}
foreach ($cc in $classicCandidates) {
    if (Test-Path $cc) {
        $bk = "$env:TEMP\psmux_117_classic_$(Get-Random)"
        Copy-Item $cc $bk -Force
        Remove-Item $cc -Force
        $classicBackups[$cc] = $bk
        Write-Info "Temporarily removed classic config: $cc"
    }
}

# =============================================================================
# TEST 1: Session starts when only XDG config is present
# =============================================================================
Write-Host ""
Write-Test "TEST 1: Start session (only XDG config present)"
Start-Process -FilePath $PSMUX -ArgumentList "new-session", "-d", "-s", $SESSION -WindowStyle Hidden | Out-Null

if (Wait-Session $SESSION 12000) {
    Write-Pass "Session '$SESSION' started with XDG config present"
} else {
    Write-Fail "Session '$SESSION' failed to start"
    # Restore and exit early
    foreach ($e in $classicBackups.GetEnumerator()) { Copy-Item $e.Value $e.Key -Force; Remove-Item $e.Value -Force }
    if ($xdgConfBackup) { Copy-Item $xdgConfBackup $XDG_CONF -Force; Remove-Item $xdgConfBackup -Force }
    elseif (-not $xdgConfPreExisted) { Cleanup }
    Write-Host ""; Write-Host "Results: $($script:TestsPassed) passed, $($script:TestsFailed) failed"
    exit 1
}

# =============================================================================
# TEST 2: Setting from XDG config is applied (status-right == marker)
# =============================================================================
Write-Host ""
Write-Test "TEST 2: XDG config setting applied (status-right contains $MARKER)"
Start-Sleep -Milliseconds 500
$opts = (& $PSMUX show-options -g -t $SESSION 2>&1) -join "`n"
Write-Info "show-options output (excerpt): $(($opts -split "`n" | Select-String 'status-right') -join ' ')"

if ($opts -match [regex]::Escape($MARKER)) {
    Write-Pass "status-right contains '$MARKER' - XDG config was loaded"
} else {
    Write-Fail "status-right does NOT contain '$MARKER' - XDG config was NOT loaded"
    Write-Info "Full show-options:"
    $opts -split "`n" | ForEach-Object { Write-Info "  $_" }
}

# =============================================================================
# CLEANUP
# =============================================================================
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Yellow
Write-Host "  CLEANUP" -ForegroundColor Yellow
Write-Host ("=" * 70) -ForegroundColor Yellow

Cleanup

# Restore classic configs
foreach ($e in $classicBackups.GetEnumerator()) {
    Copy-Item $e.Value $e.Key -Force
    Remove-Item $e.Value -Force
    Write-Info "Restored classic config: $($e.Key)"
}
# Restore XDG config if it pre-existed
if ($xdgConfBackup) {
    Copy-Item $xdgConfBackup $XDG_CONF -Force
    Remove-Item $xdgConfBackup -Force
    Write-Info "Restored XDG config: $XDG_CONF"
} elseif (-not $xdgConfPreExisted -and (Test-Path $XDG_CONF)) {
    Remove-Item $XDG_CONF -Force
    if (-not $xdgDirPreExisted) {
        $remaining = Get-ChildItem $XDG_DIR -ErrorAction SilentlyContinue
        if (-not $remaining) { Remove-Item $XDG_DIR -Force -ErrorAction SilentlyContinue }
    }
    Write-Info "Removed temp XDG config (was not pre-existing)"
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  ISSUE #117 RESULTS" -ForegroundColor White
Write-Host ("=" * 70) -ForegroundColor White
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor Red
Write-Host ("=" * 70) -ForegroundColor White

if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
