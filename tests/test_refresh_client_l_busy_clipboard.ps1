# refresh-client -l with a clipboard another window is holding open.
#
# Full sweeps 2026-10-22, 10-23, 10-24 and 10-28 failed test_mouse_key_bindings
# at "refresh-client -l makes the clipboard the top buffer": the clipboard held
# the text, yet no buffer was made.  The server read the clipboard with about
# 10 ms of retries; a clipboard history listener, an RDP clipboard bridge or an
# Office app holds the clipboard open for longer than that right after a
# change, and the command then silently stored nothing.
#
# Measured on master 9b5c3e0e with tests\clipboard_holder.cs holding it:
#   hold 0 ms 4/4 read, 30 ms 1/4, 100 ms 0/4, 300 ms 0/4.
#
# tmux waits up to TTY_QUERY_TIMEOUT (5 s, tty.c) for the clipboard answer; psmux
# now waits for the clipboard to be free for as long, and returns as soon as it
# reads.
#
# Safety: private PSMUX_DATA_DIR, its own -L namespace, kill-server only with -L,
# the user's clipboard is saved and restored, the holder caps itself at 5 s and
# is stopped by PID.
#
# Run: pwsh -NoProfile -ExecutionPolicy Bypass -File tests\test_refresh_client_l_busy_clipboard.ps1
$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow; $script:Skip++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkGray }

foreach ($v in 'PSMUX_SESSION_NAME','PSMUX_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') { Remove-Item "Env:\$v" -EA SilentlyContinue }
$savedDataDir = $env:PSMUX_DATA_DIR
$root = Join-Path $env:TEMP "prcl_$PID"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "d"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null
$NS = "rclbusy_$PID"
function P { & $PSMUX -L $NS @args 2>&1 }

$holder = Join-Path $root "clipboard_holder.exe"
& "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe" "-nologo" "-r:System.Windows.Forms.dll" "-out:$holder" (Join-Path $PSScriptRoot "clipboard_holder.cs") 2>&1 | Out-Null
if (-not (Test-Path $holder)) { Write-Host "FATAL: could not compile clipboard_holder.cs" -ForegroundColor Red; exit 1 }

function Set-ClipboardVerified([string]$Value) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 5000) {
        try { Set-Clipboard -Value $Value -EA Stop } catch {}
        Start-Sleep -Milliseconds 50
        $now = $(try { Get-Clipboard -Raw -EA Stop } catch { $null })
        if ($null -ne $now -and $now.TrimEnd("`r", "`n") -eq $Value) { return $true }
    }
    return $false
}

# One refresh-client -l with the clipboard held for $HoldMs. Returns the top
# buffer and how long the command took.
$script:holders = @()
function Try-Read([int]$HoldMs, [string]$Value) {
    P set-buffer OLDBUF | Out-Null
    if (-not (Set-ClipboardVerified $Value)) { return @{ ok = $null } }
    $ready = Join-Path $root "ready_${HoldMs}_$([guid]::NewGuid().ToString('N').Substring(0,6))"
    $hp = $null
    if ($HoldMs -gt 0) {
        $hp = Start-Process $holder -ArgumentList $HoldMs, $ready -PassThru -WindowStyle Hidden
        $script:holders += $hp
        $w = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path $ready) -and $w.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 2 }
        if (-not (Test-Path $ready)) { return @{ ok = $null } }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    P refresh-client -l | Out-Null
    $ms = $sw.ElapsedMilliseconds
    $top = (P show-buffer) -join ''
    if ($hp) { $hp.WaitForExit(7000) | Out-Null }
    return @{ ok = ($top -eq $Value); top = $top; ms = $ms }
}

$savedClip = $null; $clipSaved = $false
try { $savedClip = Get-Clipboard -Raw -EA Stop; $clipSaved = $true } catch {}

Write-Host "`n=== refresh-client -l with a busy clipboard ($PSMUX) ===" -ForegroundColor Cyan
try {
    if (-not (Set-ClipboardVerified "RCLPROBE")) { Write-Skip "the desktop refuses clipboard access to this process"; throw "noclip" }
    P new-session -d -s r -x 80 -y 24 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000 -and ((P has-session -t r) -match 'no server|can.t find')) { Start-Sleep -Milliseconds 150 }

    Write-Host "`n[1] a free clipboard becomes the top buffer at once" -ForegroundColor Yellow
    $free = @()
    for ($i = 0; $i -lt 5; $i++) {
        $r = Try-Read 0 "RCLFREE$i"
        if ($r.ok) { $free += $r.ms } else { Write-Fail "free clipboard: top buffer [$($r.top)] expected [RCLFREE$i]" }
    }
    if ($free.Count -eq 5) {
        $avg = [math]::Round(($free | Measure-Object -Average).Average, 1)
        Write-Pass "5/5 free reads made the buffer (avg ${avg} ms per command)"
    }

    Write-Host "`n[2] the clipboard held open 300 ms by another window" -ForegroundColor Yellow
    $ok = 0; $held = @()
    for ($i = 0; $i -lt 4; $i++) {
        $r = Try-Read 300 "RCLHELD300x$i"
        if ($null -eq $r.ok) { Write-Skip "the holder could not take the clipboard"; continue }
        if ($r.ok) { $ok++; $held += $r.ms } else { Write-Info "hold 300: top buffer [$($r.top)] after $($r.ms) ms" }
    }
    if ($ok -eq 4) { Write-Pass "4/4 reads waited for the clipboard and made the buffer" } else { Write-Fail "$ok/4 reads made the buffer while the clipboard was held 300 ms" }

    Write-Host "`n[3] held 1500 ms: the command returns once the clipboard is free, not at the timeout" -ForegroundColor Yellow
    $r = Try-Read 1500 "RCLHELD1500"
    if ($null -eq $r.ok) { Write-Skip "the holder could not take the clipboard" }
    elseif ($r.ok -and $r.ms -lt 4500) { Write-Pass "buffer made after $($r.ms) ms" }
    else { Write-Fail "top buffer [$($r.top)] after $($r.ms) ms, expected RCLHELD1500 well inside 5 s" }

    Write-Host "`n[4] chained: refresh-client -l ; show-buffer in one command list sees the clipboard" -ForegroundColor Yellow
    P set-buffer OLDBUF | Out-Null
    [void](Set-ClipboardVerified "RCLCHAIN")
    $ready = Join-Path $root "ready_chain"
    $hp = Start-Process $holder -ArgumentList 300, $ready -PassThru -WindowStyle Hidden
    $script:holders += $hp
    $w = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path $ready) -and $w.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 2 }
    $out = (P refresh-client -l `; show-buffer) -join ''
    $hp.WaitForExit(7000) | Out-Null
    if ($out -eq 'RCLCHAIN') { Write-Pass "the next command saw the clipboard text" } else { Write-Fail "chained show-buffer gave [$out]" }

    $metricsDir = Join-Path $env:USERPROFILE ".psmux-test-data\metrics"
    New-Item -ItemType Directory -Force $metricsDir | Out-Null
    $m = [ordered]@{
        test = "refresh_client_l_busy_clipboard"; when = (Get-Date).ToString("o")
        free_read_ms = $free; held300_read_ms = $held; held1500_read_ms = $r.ms
    }
    $m | ConvertTo-Json | Set-Content (Join-Path $metricsDir "refresh_client_l_busy_clipboard.json")
}
catch { if ($_.Exception.Message -ne 'noclip') { Write-Fail "unexpected: $_" } }
finally {
    foreach ($h in $script:holders) { if ($h -and -not $h.HasExited) { Stop-Process -Id $h.Id -Force -EA SilentlyContinue } }
    P kill-server | Out-Null
    if ($clipSaved) {
        $back = $false
        for ($i = 0; $i -lt 50 -and -not $back; $i++) {
            try { Set-Clipboard -Value $savedClip -EA Stop } catch {}
            $back = ($(try { Get-Clipboard -Raw -EA Stop } catch { $null }) -eq $savedClip)
            if (-not $back) { Start-Sleep -Milliseconds 100 }
        }
        if (-not $back) { Write-Host "  [WARN] the clipboard could not be restored" -ForegroundColor Yellow }
    }
    $env:PSMUX_DATA_DIR = $savedDataDir
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $root -EA SilentlyContinue
}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass  Failed: $script:Fail  Skipped: $script:Skip"
exit $script:Fail
