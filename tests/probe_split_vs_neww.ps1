# probe_split_vs_neww.ps1 — split-window measures ~0.2ms server side while
# new-window measures ~85ms in the SAME burst, even though both create a pane
# running the same shell. Either new-window is missing a fast path split takes,
# or the splits are failing instantly and not creating anything at all. This
# verifies by COUNTING panes and windows before and after, so a refusal cannot
# masquerade as speed.
param([string]$Ns = "sv$PID", [int]$N = 12, [string]$Psmux = "")
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
    $out = @()
    while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq "") { break }; $out += $l }
    $ms = $sw.Elapsed.TotalMilliseconds
    $tcp.Close()
    return @{ ms = $ms; out = $out }
}
function Med { param([double[]]$v) $s = $v | Sort-Object; $n = $s.Count; if ($n % 2 -eq 1) { $s[[int](($n-1)/2)] } else { ($s[$n/2-1]+$s[$n/2])/2 } }
function Seq { param([double[]]$v) return (($v | ForEach-Object { "{0,7:N1}" -f $_ }) -join "") }
function PaneCount { param($port, $key) (OneShot $port $key @("TARGET p", "list-panes -a")).out.Count }
function WinCount  { param($port, $key) (OneShot $port $key @("TARGET p", "list-windows")).out.Count }

foreach ($mode in @("new-window", "split-window")) {
    Cleanup
    & $Psmux -L $Ns new-session -d -s p 2>&1 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 15000) { & $Psmux -L $Ns has-session -t p 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 20 }
    Start-Sleep -Milliseconds 1200
    $port = [int]((Get-Content "$DataDir\$($Ns)__p.port" -Raw).Trim())
    $key = (Get-Content "$DataDir\$($Ns)__p.key" -Raw).Trim()

    $panes0 = PaneCount $port $key
    $wins0 = WinCount $port $key
    $t = @()
    for ($i = 0; $i -lt $N; $i++) { $t += (OneShot $port $key @("TARGET p", $mode, "session-info")).ms }
    Start-Sleep -Milliseconds 700
    $panes1 = PaneCount $port $key
    $wins1 = WinCount $port $key

    Write-Host ""
    Write-Host ("[$mode]  x$N back to back, no process spawn") -ForegroundColor Yellow
    Write-Host ("  " + (Seq $t))
    Write-Host ("  median={0:N1}ms   panes {1} -> {2} (created {3})   windows {4} -> {5} (created {6})" -f `
        (Med $t), $panes0, $panes1, ($panes1 - $panes0), $wins0, $wins1, ($wins1 - $wins0)) -ForegroundColor Magenta
    if (($panes1 - $panes0) -lt $N) {
        Write-Host ("  WARNING: only {0}/{1} panes actually appeared — some calls were REFUSED, not fast" -f ($panes1 - $panes0), $N) -ForegroundColor Red
    } else {
        Write-Host ("  all {0} panes really exist: the timing is genuine work" -f ($panes1 - $panes0)) -ForegroundColor Green
    }
}
Cleanup
Write-Host "done."
