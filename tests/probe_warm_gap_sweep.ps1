# probe_warm_gap_sweep.ps1 — the warm pane pool is replenished OFF the command
# path, during an idle gap. A back to back burst of new-window therefore never
# lets it refill, so every call after the first pays a cold ConPTY + shell spawn.
# This sweeps the gap between calls to prove exactly that, and to show the hit
# rate a real user (who creates windows seconds apart) actually gets.
param([string]$Ns = "wg$PID", [int]$N = 10, [string]$Psmux = "")
$ErrorActionPreference = "Continue"
if (-not $Psmux) { $Psmux = Join-Path (Split-Path -Parent $PSScriptRoot) "target\release\psmux.exe" }
$Psmux = (Resolve-Path $Psmux).Path
$DataDir = Join-Path $env:USERPROFILE ".psmux"

function Cleanup {
    try { & $Psmux -L $Ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 250
    Get-ChildItem "$DataDir\$($Ns)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
function OneShot {
    param([int]$Port, [string]$Key, [string[]]$Lines)
    $tcp = New-Object System.Net.Sockets.TcpClient; $tcp.NoDelay = $true
    $tcp.Connect("127.0.0.1", $Port)
    $ns2 = $tcp.GetStream(); $ns2.ReadTimeout = 30000
    $wr = New-Object System.IO.StreamWriter($ns2); $wr.AutoFlush = $false
    $rd = New-Object System.IO.StreamReader($ns2)
    $wr.WriteLine("AUTH $Key"); $wr.Flush()
    if ($rd.ReadLine() -ne "OK") { $tcp.Close(); throw "auth" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($l in $Lines) { $wr.WriteLine($l) }
    $wr.Flush()
    while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq "") { break } }
    $ms = $sw.Elapsed.TotalMilliseconds
    $tcp.Close(); return $ms
}
function Med { param([double[]]$v) $s = $v | Sort-Object; $n = $s.Count; if ($n % 2 -eq 1) { $s[[int](($n-1)/2)] } else { ($s[$n/2-1]+$s[$n/2])/2 } }
function Seq { param([double[]]$v) return (($v | ForEach-Object { "{0,7:N1}" -f $_ }) -join "") }

Write-Host ""
Write-Host "=== new-window cost vs the idle gap allowed before each call ===" -ForegroundColor Yellow
Write-Host "    (raw socket, no psmux.exe process start in the measurement)" -ForegroundColor DarkGray
Write-Host ""
foreach ($gap in @(0, 50, 100, 200, 400, 800, 1500)) {
    Cleanup
    & $Psmux -L $Ns new-session -d -s p 2>&1 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) { & $Psmux -L $Ns has-session -t p 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 20 }
    Start-Sleep -Milliseconds 1200
    $port = [int]((Get-Content "$DataDir\$($Ns)__p.port" -Raw).Trim())
    $key = (Get-Content "$DataDir\$($Ns)__p.key" -Raw).Trim()

    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        if ($gap -gt 0) { Start-Sleep -Milliseconds $gap }
        $t += (OneShot $port $key @("TARGET p", "new-window", "session-info"))
    }
    # A sample under 5ms could only have come from a ready made pane: a cold
    # CreatePseudoConsole plus shell CreateProcess cannot finish that fast.
    $hits = ($t | Where-Object { $_ -lt 5 }).Count
    Write-Host ("  gap={0,5}ms  med={1,7:N1}  min={2,6:N1}  warm hits={3,2}/{4}   {5}" -f `
        $gap, (Med $t), ($t | Measure-Object -Minimum).Minimum, $hits, $N, (Seq $t)) -ForegroundColor Cyan
}
Cleanup
Write-Host ""
Write-Host "done."
