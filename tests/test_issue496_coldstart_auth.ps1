# Issue #496: intermittent "psmux: auth failed" on cold start
#
# Root cause: the server wrote the .port readiness beacon BEFORE the .key
# credential (and re-truncated the .key after .port was visible), so a bare
# `psmux` cold start could read an empty key and send a malformed AUTH line.
# Reproduced at ~20 percent with reboot-stale registry files present.
#
# This suite proves the fix from every angle:
#   Part A: reboot-stale cold start loop (the original reproduction shape)
#   Part B: tight port/key ordering probe on cold server spawn
#   Part C: second-run / repeat bare starts (reporter's "works on retry")
#   Part D: Win32 TUI visual verification (mandatory layer)

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Kill-AllPsmux {
    Get-ChildItem "$psmuxDir\*.port" -EA SilentlyContinue | ForEach-Object {
        & $PSMUX kill-session -t $_.BaseName 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 800
    Get-Process psmux -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -EA SilentlyContinue }
    Start-Sleep -Milliseconds 400
}

function Clean-StateFiles {
    Remove-Item "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.pid","$psmuxDir\*.sid","$psmuxDir\*.spawnlock","$psmuxDir\last_session","$psmuxDir\next_session_id" -Force -EA SilentlyContinue
}

# bare psmux needs a real console; run it via cmd with stderr captured
$RUNNER = "$env:TEMP\psmux_issue496_runner.cmd"
@"
@echo off
psmux 2>"%~1"
echo EXITCODE=%errorlevel%>>"%~1"
"@ | Set-Content -Path $RUNNER -Encoding ASCII

Write-Host "`n=== Issue #496 Tests ===" -ForegroundColor Cyan

# === Part A: reboot-stale cold start loop ===
# Every reboot leaves .port/.key/.pid files behind (servers die with the OS).
# Bare psmux with that stale state plus zero processes is the exact shape that
# failed AUTH ~20 percent of the time before the fix.
Write-Host "`n[Part A] Reboot-stale cold start x10 (was ~20 percent AUTHFAIL)" -ForegroundColor Yellow
$authFails = 0
$okCount = 0
for ($i = 1; $i -le 10; $i++) {
    Kill-AllPsmux
    Clean-StateFiles

    # build reboot-stale state: live warm + user session, then hard-kill (power loss)
    & $PSMUX new-session -d -s coldsim 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    Set-Content "$psmuxDir\last_session" "coldsim" -NoNewline
    Get-Process psmux -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -EA SilentlyContinue }
    Start-Sleep -Milliseconds 800

    $err = "$env:TEMP\psmux_issue496_err.txt"
    Remove-Item $err -Force -EA SilentlyContinue
    $proc = Start-Process cmd -ArgumentList "/c", $RUNNER, $err -WindowStyle Minimized -PassThru

    $verdict = "TIMEOUT"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        Start-Sleep -Milliseconds 250
        $errText = if (Test-Path $err) { [string](Get-Content $err -Raw -EA SilentlyContinue) } else { "" }
        if ($errText -match "auth failed") { $verdict = "AUTHFAIL"; break }
        if ($errText -match "EXITCODE=") { $verdict = "EXIT"; break }
        $names = @(& $PSMUX ls -F '#{session_name}' 2>$null | Where-Object { $_ -and $_ -ne "__warm__" })
        if ($names.Count -ge 1) { $verdict = "OK"; break }
    }
    if ($verdict -eq "AUTHFAIL") { $authFails++ }
    elseif ($verdict -eq "OK") { $okCount++ }
    Write-Host "    iter ${i}: $verdict"
    Kill-AllPsmux
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}
if ($authFails -eq 0 -and $okCount -ge 8) { Write-Pass "10 reboot-stale cold starts: 0 auth failures, $okCount OK" }
elseif ($authFails -gt 0) { Write-Fail "BUG PRESENT: $authFails of 10 cold starts hit 'auth failed'" }
else { Write-Fail "only $okCount of 10 cold starts produced a live session" }

# === Part B: port/key ordering probe ===
# The .port file is the readiness beacon. From the instant it exists, the
# sibling .key MUST be non-empty. Tight-poll the transition on cold spawns.
Write-Host "`n[Part B] .key readable the instant .port appears (x5 cold spawns)" -ForegroundColor Yellow
$orderViolations = 0
for ($i = 1; $i -le 5; $i++) {
    Kill-AllPsmux
    Clean-StateFiles
    $sess = "ord496_$i"
    $portPath = "$psmuxDir\$sess.port"
    $keyPath = "$psmuxDir\$sess.key"
    $env:PSMUX_NO_WARM = "1"
    Start-Process -FilePath $PSMUX -ArgumentList "new-session","-d","-s",$sess -WindowStyle Hidden
    $env:PSMUX_NO_WARM = $null
    $seenPort = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) {
        if ([System.IO.File]::Exists($portPath)) {
            $seenPort = $true
            # the very first moment .port is visible, .key must have content
            $key = ""
            try { $key = [System.IO.File]::ReadAllText($keyPath).Trim() } catch {}
            if ($key.Length -lt 8) {
                $orderViolations++
                Write-Host "    iter ${i}: VIOLATION key='$key' at port appearance" -ForegroundColor Red
            } else {
                Write-Host "    iter ${i}: key ready ($($key.Length) chars) when port appeared"
            }
            break
        }
    }
    if (-not $seenPort) { Write-Host "    iter ${i}: port never appeared" -ForegroundColor Red; $orderViolations++ }
    Kill-AllPsmux
}
if ($orderViolations -eq 0) { Write-Pass "5 of 5 cold spawns: .key complete before .port beacon" }
else { Write-Fail "$orderViolations ordering violations (key not ready when port appeared)" }

# === Part C: repeated bare starts (reporter retry path) ===
Write-Host "`n[Part C] Back-to-back bare starts stay healthy" -ForegroundColor Yellow
Kill-AllPsmux
Clean-StateFiles
$err1 = "$env:TEMP\psmux_issue496_err1.txt"
Remove-Item $err1 -Force -EA SilentlyContinue
$p1 = Start-Process cmd -ArgumentList "/c", $RUNNER, $err1 -WindowStyle Minimized -PassThru
Start-Sleep -Seconds 5
$names1 = @(& $PSMUX ls -F '#{session_name}' 2>$null | Where-Object { $_ -and $_ -ne "__warm__" })
$e1 = if (Test-Path $err1) { [string](Get-Content $err1 -Raw -EA SilentlyContinue) } else { "" }
if ($names1.Count -ge 1 -and $e1 -notmatch "auth failed") { Write-Pass "first bare start attached (session: $($names1 -join ','))" }
else { Write-Fail "first bare start failed: sessions=$($names1 -join ',') stderr=$e1" }

# detach-equivalent: kill the client window but keep the session server alive
try { Stop-Process -Id $p1.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep -Seconds 1
$err2 = "$env:TEMP\psmux_issue496_err2.txt"
Remove-Item $err2 -Force -EA SilentlyContinue
$p2 = Start-Process cmd -ArgumentList "/c", $RUNNER, $err2 -WindowStyle Minimized -PassThru
Start-Sleep -Seconds 5
$e2 = if (Test-Path $err2) { [string](Get-Content $err2 -Raw -EA SilentlyContinue) } else { "" }
if ($e2 -notmatch "auth failed") { Write-Pass "second bare start (existing server) no auth failure" }
else { Write-Fail "second bare start hit auth failed: $e2" }
Kill-AllPsmux
try { Stop-Process -Id $p2.Id -Force -EA SilentlyContinue } catch {}

# === Part D: Win32 TUI visual verification ===
Write-Host "`n[Part D] Win32 TUI visual verification" -ForegroundColor Yellow
Clean-StateFiles
# stale state present, visible attached window — the user-facing scenario
& $PSMUX new-session -d -s coldsim 2>&1 | Out-Null
Start-Sleep -Seconds 4
Get-Process psmux -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -EA SilentlyContinue }
Start-Sleep -Milliseconds 800

$tuiProc = Start-Process -FilePath $PSMUX -PassThru
Start-Sleep -Seconds 5
$tuiNames = @(& $PSMUX ls -F '#{session_name}' 2>$null | Where-Object { $_ -and $_ -ne "__warm__" })
if ($tuiNames.Count -ge 1) { Write-Pass "TUI: bare psmux over stale state created session '$($tuiNames[0])'" }
else { Write-Fail "TUI: no session after bare psmux" }

if ($tuiNames.Count -ge 1) {
    $t = $tuiNames[0]
    $sn = (& $PSMUX display-message -t $t -p '#{session_name}' 2>&1 | Out-String).Trim()
    if ($sn -eq $t) { Write-Pass "TUI: display-message responsive (session_name=$sn)" }
    else { Write-Fail "TUI: display-message wrong: '$sn'" }

    & $PSMUX split-window -v -t $t 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    $panes = (& $PSMUX display-message -t $t -p '#{window_panes}' 2>&1 | Out-String).Trim()
    if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" }
    else { Write-Fail "TUI: expected 2 panes, got '$panes'" }

    & $PSMUX send-keys -t $t "echo ISSUE496_MARKER" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $cap = & $PSMUX capture-pane -t $t -p 2>&1 | Out-String
    if ($cap -match "ISSUE496_MARKER") { Write-Pass "TUI: send-keys/capture-pane round trip" }
    else { Write-Fail "TUI: marker not found in capture" }
}
Kill-AllPsmux
try { Stop-Process -Id $tuiProc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Clean-StateFiles
Remove-Item $RUNNER,"$env:TEMP\psmux_issue496_err*.txt" -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
