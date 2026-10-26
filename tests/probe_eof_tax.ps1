# probe_eof_tax.ps1 — is the CLI's extra new-window cost the REPLY, or the EOF
# that follows it? The one shot protocol is: reply lines, blank line, then the
# server closes. If "read to blank line" is fast but "read to EOF" is slow, the
# CLI is paying for a socket the server holds open after the work is done.
param([string]$Ns = "eof$PID", [int]$N = 15, [string]$Psmux = "")
$ErrorActionPreference = "Continue"
if (-not $Psmux) { $Psmux = Join-Path (Split-Path -Parent $PSScriptRoot) "target\release\psmux.exe" }
$Psmux = (Resolve-Path $Psmux).Path
$DataDir = Join-Path $env:USERPROFILE ".psmux"

function Cleanup {
    try { & $Psmux -L $Ns kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 200
    Get-ChildItem "$DataDir\$($Ns)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
# Returns @(msToBlankLine, msToEof)
function OneShotSplit {
    param([int]$Port, [string]$Key, [string]$Cmd)
    $tcp = New-Object System.Net.Sockets.TcpClient; $tcp.NoDelay = $true
    $tcp.Connect("127.0.0.1", $Port)
    $ns2 = $tcp.GetStream(); $ns2.ReadTimeout = 30000
    $wr = New-Object System.IO.StreamWriter($ns2); $wr.AutoFlush = $false
    $rd = New-Object System.IO.StreamReader($ns2)
    $wr.WriteLine("AUTH $Key"); $wr.Flush()
    if ($rd.ReadLine() -ne "OK") { $tcp.Close(); throw "auth" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $wr.WriteLine($Cmd); $wr.Flush()
    while ($true) { $l = $rd.ReadLine(); if ($null -eq $l) { break }; if ($l -eq "") { break } }
    $toBlank = $sw.Elapsed.TotalMilliseconds
    while ($true) { $l = $rd.ReadLine(); if ($null -eq $l) { break } }
    $toEof = $sw.Elapsed.TotalMilliseconds
    $tcp.Close()
    return @($toBlank, $toEof)
}
function Seq { param([double[]]$v) return (($v | ForEach-Object { "{0,7:N1}" -f $_ }) -join "") }
function Med { param([double[]]$v) $s = $v | Sort-Object; $n = $s.Count; if ($n % 2 -eq 1) { $s[[int](($n-1)/2)] } else { ($s[$n/2-1]+$s[$n/2])/2 } }

Cleanup
& $Psmux -L $Ns new-session -d -s p 2>&1 | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 15000) { & $Psmux -L $Ns has-session -t p 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 20 }
Start-Sleep -Milliseconds 800
$port = [int]((Get-Content "$DataDir\$($Ns)__p.port" -Raw).Trim())
$key = (Get-Content "$DataDir\$($Ns)__p.key" -Raw).Trim()

foreach ($cmd in @("list-sessions", "rename-window -t p zz", "new-window -t p", "split-window -t p")) {
    $b = @(); $e = @()
    for ($i = 0; $i -lt $N; $i++) {
        $r = OneShotSplit $port $key $cmd
        $b += $r[0]; $e += $r[1]
    }
    Write-Host ""
    Write-Host ("[{0}]" -f $cmd) -ForegroundColor Yellow
    Write-Host ("  to blank line: " + (Seq $b))
    Write-Host ("  to EOF       : " + (Seq $e))
    Write-Host ("  median blank={0:N1}ms   median EOF={1:N1}ms   EOF tax={2:N1}ms" -f (Med $b), (Med $e), ((Med $e) - (Med $b))) -ForegroundColor Magenta
}

Cleanup
Write-Host "done."
