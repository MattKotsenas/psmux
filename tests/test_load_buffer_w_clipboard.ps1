# load-buffer -w clipboard propagation tests
#
# Real tmux 3.2+ uses `load-buffer -w` to forward the loaded buffer to the
# outer terminal's system clipboard via OSC 52. psmux runs on Windows and
# has direct access to the Win32 clipboard, so `-w` should write the buffer
# contents to the system clipboard.
#
# Bug: psmux's `load-buffer` handler swallowed `-w` as a no-op, so
# clipboard-aware tools (tuicr, neovim's `+` register via tmux, lazygit, ...)
# silently produced no clipboard effect inside psmux panes.
#
# These tests use:
#   * `-L lb_w_test` for namespace isolation so they never touch your real
#     psmux server.
#   * The locally-built psmux binary (target/release first, then target/debug)
#     so the tests verify the change under development.
#   * Snapshot+restore of the host's Win32 clipboard so the developer's
#     clipboard contents survive the test run.

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Test { param($msg) Write-Host "[TEST] $msg" -ForegroundColor White }

# Resolve the under-test binary the same way test_pr27.ps1 does.
$PSMUX = "$PSScriptRoot\..\target\release\psmux.exe"
if (-not (Test-Path $PSMUX)) {
    $PSMUX = "$PSScriptRoot\..\target\debug\psmux.exe"
}
if (-not (Test-Path $PSMUX)) {
    Write-Host "[FATAL] No built psmux.exe at target/release or target/debug. Run `cargo build` first." -ForegroundColor Red
    exit 1
}
Write-Info "Using psmux binary: $PSMUX"

# psmux refuses to nest by default. If the test is itself launched from
# inside a psmux pane (common during development), these env vars trip the
# "sessions should be nested with care" guard and the new-session below
# silently fails to materialize. Clearing them for this process only is
# safe because we use `-L $NS` to isolate the whole server anyway.
$env:PSMUX_SESSION = $null
$env:TMUX = $null

$NS      = "lb_w_test"
$SESSION = "lb_w_session"

# Snapshot the user's TEXT clipboard so the test is non-destructive for
# the common case. Non-text formats (images, file lists, custom MIME) are
# NOT preserved - if your clipboard holds such content, it will be cleared
# after the test runs.
$ClipboardHadText = $false
$ClipboardBackup  = $null
try {
    $raw = Get-Clipboard -Raw -ErrorAction Stop
    if ($null -ne $raw -and $raw.Length -gt 0) {
        $ClipboardBackup  = $raw
        $ClipboardHadText = $true
    }
} catch {
    # Non-text or empty clipboard. Backup stays null.
}
if (-not $ClipboardHadText) {
    Write-Info "Original clipboard empty or non-text; will clear after tests (non-text formats not preserved)."
}

function Clear-TestClipboard {
    # Prefer the native cmdlet if present (PowerShell 7+); fall back to
    # System.Windows.Forms.Clipboard for older / WinPS hosts. Piping the
    # empty string to Set-Clipboard does NOT actually clear - it leaves
    # an empty-string text payload - so do not use that here.
    if (Get-Command Clear-Clipboard -ErrorAction SilentlyContinue) {
        try { Clear-Clipboard -ErrorAction Stop; return } catch {}
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.Clipboard]::Clear()
    } catch {
        # Last resort: leave an empty text payload. Better than the test
        # marker leaking into the developer's session.
        try { Set-Clipboard -Value '' } catch {}
    }
}

function Restore-Clipboard {
    if ($ClipboardHadText) {
        try { Set-Clipboard -Value $ClipboardBackup } catch {}
    } else {
        Clear-TestClipboard
    }
}

function Cleanup-Server {
    # `-L $NS kill-server` only affects the isolated namespace; the user's
    # default server is untouched.
    & $PSMUX -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
}

trap {
    Restore-Clipboard
    Cleanup-Server
    Write-Host "[FATAL] Unhandled error: $_" -ForegroundColor Red
    exit 1
}

# Start with a clean isolated server, then a single detached session for
# load-buffer to talk to.
Cleanup-Server
& $PSMUX -L $NS new-session -d -s $SESSION 2>&1 | Out-Null
# Server startup on Windows includes ConPTY init and named-pipe bind; can
# take a couple seconds on a busy machine.
$hasExit = 1
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    & $PSMUX -L $NS has-session -t $SESSION 2>&1 | Out-Null
    $hasExit = $LASTEXITCODE
    if ($hasExit -eq 0) { break }
}
if ($hasExit -ne 0) {
    Write-Host "[FATAL] Could not start isolated test session within 10s." -ForegroundColor Red
    Cleanup-Server
    Restore-Clipboard
    exit 1
}
Write-Info "Isolated server $NS / session $SESSION started"

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host " load-buffer -w clipboard propagation" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

# ── Test 1: load-buffer -w copies stdin to the Win32 clipboard ──────────
Write-Test "load-buffer -w copies stdin content to the system clipboard"
$marker1 = "LB-W-MARKER-$([Guid]::NewGuid().ToString().Substring(0,8))"
Set-Clipboard -Value "SENTINEL-BEFORE-TEST1"
$preCb1 = Get-Clipboard -Raw
if ($preCb1 -ne "SENTINEL-BEFORE-TEST1") {
    Write-Fail "Precondition: could not seed clipboard for test 1 (got: $preCb1)"
} else {
    $marker1 | & $PSMUX -L $NS load-buffer -w - 2>&1 | Out-Null
    $loadExit = $LASTEXITCODE
    Start-Sleep -Milliseconds 300
    $postCb1 = (Get-Clipboard -Raw)
    $postCb1Trimmed = if ($null -ne $postCb1) { $postCb1.TrimEnd("`r","`n") } else { $null }
    if ($loadExit -ne 0) {
        Write-Fail "load-buffer -w exited with code $loadExit"
    } elseif ($postCb1Trimmed -eq $marker1) {
        Write-Pass "Clipboard updated to marker (was sentinel)"
    } else {
        Write-Fail "Clipboard NOT updated. Expected '$marker1', got '$postCb1'"
    }
}

# ── Test 2: load-buffer WITHOUT -w must NOT touch the clipboard ─────────
Write-Test "load-buffer (no -w) does NOT touch the system clipboard"
$sentinel2 = "SENTINEL-BEFORE-TEST2-$([Guid]::NewGuid().ToString().Substring(0,8))"
$marker2   = "LB-NOW-MARKER-$([Guid]::NewGuid().ToString().Substring(0,8))"
Set-Clipboard -Value $sentinel2
$preCb2 = Get-Clipboard -Raw
if ($preCb2 -ne $sentinel2) {
    Write-Fail "Precondition: could not seed clipboard for test 2 (got: $preCb2)"
} else {
    $marker2 | & $PSMUX -L $NS load-buffer - 2>&1 | Out-Null
    $loadExit = $LASTEXITCODE
    Start-Sleep -Milliseconds 300
    $postCb2 = Get-Clipboard -Raw
    if ($loadExit -ne 0) {
        Write-Fail "load-buffer (no -w) exited with code $loadExit"
    } elseif ($postCb2 -eq $sentinel2) {
        Write-Pass "Clipboard untouched without -w (still sentinel)"
    } else {
        Write-Fail "Clipboard WAS changed without -w. Expected '$sentinel2', got '$postCb2'"
    }
}

# ── Test 3: -w plus -b NAME still routes to the system clipboard ────────
# The point of -w is "also forward to outer clipboard". Combining it with a
# named buffer must keep both effects: the clipboard AND the named buffer
# get the content.
#
# We use a temp file for input (rather than stdin like Tests 1 and 2) so
# the buffer content is EXACTLY $marker3 with no trailing newline. psmux's
# show-buffer command escapes embedded CR/LF as literal "\r\n" four-char
# sequences in its output, which would make round-tripping a stdin-piped
# string (where PowerShell appends a CRLF) compare awkwardly. The behavior
# of -w is orthogonal to the input source path.
Write-Test "load-buffer -w -b NAME writes to both the system clipboard AND the named buffer"
$marker3 = "LB-WB-MARKER-$([Guid]::NewGuid().ToString().Substring(0,8))"
$bufName = "tw_test_buf"
Set-Clipboard -Value "SENTINEL-BEFORE-TEST3"
$markerFile = New-TemporaryFile
try {
    [System.IO.File]::WriteAllBytes($markerFile.FullName, [System.Text.Encoding]::UTF8.GetBytes($marker3))
    & $PSMUX -L $NS load-buffer -w -b $bufName $markerFile.FullName 2>&1 | Out-Null
    $loadExit = $LASTEXITCODE
    Start-Sleep -Milliseconds 300

    # Clipboard half of the contract.
    $postCb3 = (Get-Clipboard -Raw)
    $postCb3Trimmed = if ($null -ne $postCb3) { $postCb3.TrimEnd("`r","`n") } else { $null }
    if ($loadExit -ne 0) {
        Write-Fail "load-buffer -w -b exited with code $loadExit"
    } elseif ($postCb3Trimmed -eq $marker3) {
        Write-Pass "Clipboard updated when combining -w with -b NAME"
    } else {
        Write-Fail "Clipboard NOT updated with -w -b. Expected '$marker3', got '$postCb3'"
    }

    # Named-buffer half of the contract. A regression where -w stops routing
    # to set-buffer would still pass the clipboard assertion above, so this
    # assertion is what guards the "both effects" promise.
    $bufRaw = & $PSMUX -L $NS show-buffer -b $bufName 2>&1 | Out-String
    $bufTrimmed = if ($null -ne $bufRaw) { $bufRaw.TrimEnd("`r","`n") } else { $null }
    if ($bufTrimmed -eq $marker3) {
        Write-Pass "Named buffer '$bufName' also populated with -w -b"
    } else {
        Write-Fail "Named buffer '$bufName' NOT populated with -w -b. Expected '$marker3', got '$bufRaw'"
    }
} finally {
    Remove-Item $markerFile.FullName -Force -ErrorAction SilentlyContinue
    & $PSMUX -L $NS delete-buffer -b $bufName 2>&1 | Out-Null
}

# Cleanup: restore the developer's original clipboard contents and kill the
# isolated server. Never touches the default psmux server.
Restore-Clipboard
Cleanup-Server

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host " Summary: $script:TestsPassed passed, $script:TestsFailed failed" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan

if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
