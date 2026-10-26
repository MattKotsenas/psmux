# probe_startdir_cost.ps1 — the CLI always sends `new-window -c "<cwd>"`, while a
# raw socket `new-window` sends no -c at all, and the two differ by ~70ms. This
# isolates the start directory argument as the variable, over a raw socket so no
# process start is in the measurement.
param([string]$Ns = "sd$PID", [int]$N = 12, [string]$Psmux = "")
$ErrorActionPreference = "Continue"
if (-not $Psmux) { $Psmux = Join-Path (Split-Path -Parent $PSScriptRoot) "target\release\psmux.exe" }
$Psmux = (Resolve-Path $Psmux).Path
$DataDir = Join-Path $env:USERPROFILE ".psmux"

function Cleanup {
    try { & $Psmux -L $Ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 200
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

Cleanup
& $Psmux -L $Ns new-session -d -s p 2>&1 | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 15000) { & $Psmux -L $Ns has-session -t p 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 20 }
Start-Sleep -Milliseconds 800
$port = [int]((Get-Content "$DataDir\$($Ns)__p.port" -Raw).Trim())
$key = (Get-Content "$DataDir\$($Ns)__p.key" -Raw).Trim()
$cwd = (Get-Location).Path
$repo = Split-Path -Parent $PSScriptRoot

$cases = @(
    @{ n = "new-window (no -c)";                 l = @("TARGET p", "new-window", "session-info") },
    @{ n = "new-window -c <repo root>";          l = @("TARGET p", "new-window -c `"$repo`"", "session-info") },
    @{ n = "new-window -c <server home>";        l = @("TARGET p", "new-window -c `"$env:USERPROFILE`"", "session-info") },
    @{ n = "new-window -c C:\";                  l = @("TARGET p", "new-window -c `"C:\`"", "session-info") },
    @{ n = "new-window (no -c) again";           l = @("TARGET p", "new-window", "session-info") },
    @{ n = "split-window (no -c)";               l = @("TARGET p", "split-window", "session-info") },
    @{ n = "split-window -c <repo root>";        l = @("TARGET p", "split-window -c `"$repo`"", "session-info") },
    @{ n = "rename-window (control)";            l = @("TARGET p", "rename-window `"zz`"", "session-info") }
)
Write-Host ""
Write-Host "=== raw socket, no process start, N=$N each ===" -ForegroundColor Yellow
foreach ($c in $cases) {
    $t = @()
    for ($i = 0; $i -lt $N; $i++) { $t += (OneShot $port $key $c.l) }
    Write-Host ("  {0,-30} med={1,7:N1}  min={2,7:N1}   {3}" -f $c.n, (Med $t), ($t | Measure-Object -Minimum).Minimum, (Seq $t)) -ForegroundColor Cyan
}
Cleanup
Write-Host "done."
