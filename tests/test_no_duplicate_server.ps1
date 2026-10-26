# Regression: two servers must never run for the same session name (P0, issue #2).
#
# ROOT CAUSE (pre-fix): `new-session -s X` cold-spawns a server after a
# non-atomic "does X already exist?" check. Under load `has-session` false-
# negatives (or two creators race), so two `server -s X` bind different ephemeral
# ports, desync the `X.port`/`.key` files, and the session wedges / "appears
# lost" (blank attach, `os error 10060`, kill-session can't reach it).
#
# FIX: run_server acquires a Windows named mutex keyed on the session base name
# and exits immediately if another live server already owns it (fail-open on any
# FFI hiccup; warm/standby servers exempt).
#
# This test spawns a second `server -s <name>` while the first is alive and
# asserts the second EXITS and only one server survives. Isolated USERPROFILE.

$ErrorActionPreference = "Continue"
$PSMUX = $env:PSMUX_EXE
if (-not $PSMUX -or -not (Test-Path $PSMUX)) { $PSMUX = "$PSScriptRoot\..\target\release\tmux.exe" }
if (-not (Test-Path $PSMUX)) { $PSMUX = "$PSScriptRoot\..\target\debug\tmux.exe" }
if (-not (Test-Path $PSMUX)) { Write-Host "FATAL: no psmux exe ($PSMUX)" -ForegroundColor Red; exit 2 }

$tmpHome = Join-Path $env:TEMP ("psmux_dup_" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory (Join-Path $tmpHome ".psmux") -Force | Out-Null
$env:USERPROFILE = $tmpHome; $env:HOME = $tmpHome
$env:PSMUX_ALLOW_NESTING = "1"
$name = "dupguard"
$pass = 0; $fail = 0
function Result($n,$ok,$m){ if($ok){$script:pass++;Write-Host "  PASS  $n" -ForegroundColor Green}else{$script:fail++;Write-Host "  FAIL  $n ($m)" -ForegroundColor Red} }

$spawned = @()
try {
    $a = Start-Process -FilePath $PSMUX -ArgumentList 'server','-s',$name -WindowStyle Hidden -PassThru
    $spawned += $a
    Start-Sleep -Seconds 2
    $b = Start-Process -FilePath $PSMUX -ArgumentList 'server','-s',$name -WindowStyle Hidden -PassThru
    $spawned += $b
    Start-Sleep -Seconds 2

    $aAlive  = $null -ne (Get-Process -Id $a.Id -EA SilentlyContinue) -and -not (Get-Process -Id $a.Id -EA SilentlyContinue).HasExited
    $bProc   = Get-Process -Id $b.Id -EA SilentlyContinue
    $bExited = ($null -eq $bProc) -or $bProc.HasExited
    Result "first server stays alive"            $aAlive  "A exited unexpectedly"
    Result "duplicate second server exits"        $bExited "B (duplicate) is still running"

    $live = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "server -s $name" })
    Result "exactly one server survives"          ($live.Count -eq 1) "found $($live.Count)"
}
finally {
    foreach ($p in $spawned) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue }
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "server -s $name" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
    Start-Sleep -Milliseconds 300
    Remove-Item -Recurse -Force $tmpHome -EA SilentlyContinue
}
Write-Host ""
Write-Host "no-duplicate-server: $pass passed, $fail failed" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 } else { exit 0 }
