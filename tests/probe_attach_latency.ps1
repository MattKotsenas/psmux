# probe_attach_latency.ps1 — time to attach to an existing session.
#
# An attached psmux client needs a real console: hosted under a bare ConPTY that
# never answers terminal queries it emits its setup sequences and then waits, so
# a ConPTY harness measures the harness, not the product. Launch it in a real
# console instead and observe the milestone from the SERVER, which is the only
# vantage point that cannot be faked: poll list-clients on the wire (~0.5ms per
# poll) until the session reports an attached client. The client paints its
# first frame immediately after that registration.
param([string]$Ns = "at$PID", [int]$N = 15, [string]$Psmux = "")
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
    $ns2 = $tcp.GetStream(); $ns2.ReadTimeout = 20000
    $wr = New-Object System.IO.StreamWriter($ns2); $wr.AutoFlush = $false
    $rd = New-Object System.IO.StreamReader($ns2)
    $wr.WriteLine("AUTH $Key"); $wr.Flush()
    if ($rd.ReadLine() -ne "OK") { $tcp.Close(); throw "auth" }
    foreach ($l in $Lines) { $wr.WriteLine($l) }
    $wr.Flush()
    $out = @()
    while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq "") { break }; $out += $l }
    $tcp.Close(); return $out
}
function Med { param([double[]]$v) if (-not $v -or $v.Count -eq 0) { return [double]::NaN }; $s = $v | Sort-Object; $c = $s.Count; if ($c % 2 -eq 1) { $s[[int](($c-1)/2)] } else { ($s[$c/2-1]+$s[$c/2])/2 } }
function P90 { param([double[]]$v) $s = $v | Sort-Object; $s[[Math]::Min($s.Count-1, [int][Math]::Ceiling(0.9*$s.Count)-1)] }
function Seq { param([double[]]$v) return (($v | ForEach-Object { "{0,7:N1}" -f $_ }) -join "") }

Cleanup
& $Psmux -L $Ns new-session -d -s p 2>&1 | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 15000) { & $Psmux -L $Ns has-session -t p 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 20 }
Start-Sleep -Milliseconds 1500
$port = [int]((Get-Content "$DataDir\$($Ns)__p.port" -Raw).Trim())
$key = (Get-Content "$DataDir\$($Ns)__p.key" -Raw).Trim()

# An attached client must not inherit this shell's session routing.
$saved = $env:PSMUX_SESSION_NAME; $env:PSMUX_SESSION_NAME = $null
$t = @()
for ($i = 0; $i -lt $N; $i++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $Psmux -ArgumentList @("-L", $Ns, "attach", "-t", "p") -PassThru -WindowStyle Minimized
    $seen = -1
    while ($sw.ElapsedMilliseconds -lt 15000) {
        $c = OneShot $port $key @("list-clients -t p")
        if ($c.Count -gt 0) { $seen = $sw.Elapsed.TotalMilliseconds; break }
    }
    if ($seen -ge 0) { $t += $seen }
    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
    # wait for the server to drop the client again before the next sample
    $w = [Diagnostics.Stopwatch]::StartNew()
    while ($w.ElapsedMilliseconds -lt 6000) {
        if ((OneShot $port $key @("list-clients -t p")).Count -eq 0) { break }
        Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds 200
}
$env:PSMUX_SESSION_NAME = $saved

Write-Host ""
Write-Host "=== attach to an existing session: launch -> server registers the client ===" -ForegroundColor Yellow
Write-Host ("  " + (Seq $t))
if ($t.Count -gt 0) {
    Write-Host ("  n={0}  med={1:N1}ms  min={2:N1}ms  p90={3:N1}ms  max={4:N1}ms" -f `
        $t.Count, (Med $t), ($t | Measure-Object -Minimum).Minimum, (P90 $t), ($t | Measure-Object -Maximum).Maximum) -ForegroundColor Magenta
} else {
    Write-Host "  NO SAMPLES: no client ever registered" -ForegroundColor Red
}
Cleanup
Write-Host "done."
