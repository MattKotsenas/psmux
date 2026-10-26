# probe_newsession_poll_tax.ps1 — how long after a session is genuinely ready
# does `psmux new-session` actually return?
#
# The client waits by polling, so the sleep between probes is pure launch
# latency. To measure ONLY that (and not the server's own startup time, which
# drifts with machine load by far more than the poll interval), a watcher in a
# separate runspace evaluates the SAME readiness predicate the client uses, at
# ~1ms resolution:
#
#     .port file exists -> TCP connect succeeds -> AUTH -> `list-windows`
#     replies with a non-empty, non-error body (a detached session's initial
#     window exists)
#
# `returned - ready` is then the detection latency the poll interval costs,
# independent of how long the server itself took.
param([string]$Ns = "pt$PID", [int]$N = 15, [string]$Psmux = "", [switch]$NoWarm)
$ErrorActionPreference = "Continue"
if (-not $Psmux) { $Psmux = Join-Path (Split-Path -Parent $PSScriptRoot) "target\release\psmux.exe" }
$Psmux = (Resolve-Path $Psmux).Path
$imgName = [IO.Path]::GetFileNameWithoutExtension($Psmux).ToLower()
if ($imgName -notin @("psmux", "pmux", "tmux")) {
    Write-Host "REFUSING: '$imgName' is not a recognised server image name (session.rs gates it); the warm claim would be skipped and the measurement would be of the rename" -ForegroundColor Red
    exit 1
}
$DataDir = Join-Path $env:USERPROFILE ".psmux"

function Cleanup {
    try { & $Psmux -L $Ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 250
    Get-ChildItem "$DataDir\$($Ns)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
function Med { param([double[]]$v) if (-not $v -or $v.Count -eq 0) { return [double]::NaN }; $s = $v | Sort-Object; $c = $s.Count; if ($c % 2 -eq 1) { $s[[int](($c-1)/2)] } else { ($s[$c/2-1]+$s[$c/2])/2 } }
function P90 { param([double[]]$v) $s = $v | Sort-Object; $s[[Math]::Min($s.Count-1, [int][Math]::Ceiling(0.9*$s.Count)-1)] }
function Seq { param([double[]]$v) return (($v | ForEach-Object { "{0,7:N1}" -f $_ }) -join "") }

$watcher = {
    param($pf, $kf)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 30000) {
        if ((Test-Path $pf) -and (Test-Path $kf)) {
            $raw = try { (Get-Content $pf -Raw).Trim() } catch { "" }
            $key = try { (Get-Content $kf -Raw).Trim() } catch { "" }
            if ($raw -match '^\d+$' -and $key) {
                try {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $tcp.NoDelay = $true
                    $tcp.Connect("127.0.0.1", [int]$raw)
                    $ns2 = $tcp.GetStream(); $ns2.ReadTimeout = 2000
                    $wr = New-Object System.IO.StreamWriter($ns2); $wr.AutoFlush = $false
                    $rd = New-Object System.IO.StreamReader($ns2)
                    $wr.WriteLine("AUTH $key"); $wr.Flush()
                    if ($rd.ReadLine() -eq "OK") {
                        $wr.WriteLine("list-windows"); $wr.Flush()
                        $body = ""
                        while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq "") { break }; $body += $l }
                        $tcp.Close()
                        if ($body.Trim() -and -not $body.StartsWith("ERROR")) { return $sw.Elapsed.TotalMilliseconds }
                    } else { $tcp.Close() }
                } catch {}
            }
        }
    }
    return -1
}

$ready = @(); $ret = @(); $tax = @()
Write-Host ""
Write-Host ("=== new-session -d: readiness vs CLI return   (warm pool: {0})   {1} ===" -f $(if ($NoWarm) { "DISABLED" } else { "enabled" }), $Psmux) -ForegroundColor Yellow

for ($i = 0; $i -lt $N; $i++) {
    Cleanup
    if (-not $NoWarm) {
        & $Psmux -L $Ns new-session -d -s primer 2>&1 | Out-Null
        & $Psmux -L $Ns kill-session -t primer 2>&1 | Out-Null
        $w = [Diagnostics.Stopwatch]::StartNew()
        while ($w.ElapsedMilliseconds -lt 10000 -and -not (Test-Path "$DataDir\$($Ns)____warm__.port")) { Start-Sleep -Milliseconds 15 }
        Start-Sleep -Milliseconds 1200
    }
    $sess = "s$i"
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $null = $ps.AddScript($watcher).AddArgument("$DataDir\$($Ns)__$sess.port").AddArgument("$DataDir\$($Ns)__$sess.key")
    $h = $ps.BeginInvoke()

    $env:PSMUX_NO_WARM = $(if ($NoWarm) { "1" } else { $null })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $Psmux -L $Ns new-session -d -s $sess 2>&1 | Out-Null
    $sw.Stop()
    $env:PSMUX_NO_WARM = $null
    $readyMs = [double](($ps.EndInvoke($h)) | Select-Object -First 1)
    $rs.Close()
    if ($readyMs -ge 0) {
        $ready += $readyMs
        $ret += $sw.Elapsed.TotalMilliseconds
        $tax += ($sw.Elapsed.TotalMilliseconds - $readyMs)
    }
}
Write-Host ("  ready (same predicate) : " + (Seq $ready))
Write-Host ("  CLI returned at        : " + (Seq $ret))
Write-Host ("  poll detection tax     : " + (Seq $tax)) -ForegroundColor Magenta
Write-Host ("  TAX  median={0:N1}  min={1:N1}  p90={2:N1}  max={3:N1}   (ready median={4:N1}, returned median={5:N1})" -f `
    (Med $tax), ($tax | Measure-Object -Minimum).Minimum, (P90 $tax), ($tax | Measure-Object -Maximum).Maximum, (Med $ready), (Med $ret)) -ForegroundColor Magenta
Cleanup
Write-Host "done."
