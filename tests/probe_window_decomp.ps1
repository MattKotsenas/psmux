# probe_window_decomp.ps1 — per sample decomposition of window creation cost.
# Prints EVERY sample, not an aggregate, because the aggregate hides whether the
# spare shell pool is hit or missed on each call.
param([string]$Ns = "wdp$PID", [int]$N = 20, [int]$GapMs = 0, [string]$Psmux = "")

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
    param([int]$Port, [string]$Key, [string]$Cmd)
    $tcp = New-Object System.Net.Sockets.TcpClient; $tcp.NoDelay = $true
    $tcp.Connect("127.0.0.1", $Port)
    $ns2 = $tcp.GetStream(); $ns2.ReadTimeout = 30000
    $wr = New-Object System.IO.StreamWriter($ns2); $wr.AutoFlush = $false
    $rd = New-Object System.IO.StreamReader($ns2)
    $wr.WriteLine("AUTH $Key"); $wr.Flush()
    if ($rd.ReadLine() -ne "OK") { $tcp.Close(); throw "auth" }
    $wr.WriteLine($Cmd); $wr.Flush()
    $out = @()
    while ($true) { $l = $rd.ReadLine(); if ($null -eq $l -or $l -eq "") { break }; $out += $l }
    $tcp.Close(); return $out
}
function Seq { param([double[]]$v) return (($v | ForEach-Object { "{0,7:N1}" -f $_ }) -join "") }
function Summ {
    param([string]$label, [double[]]$v)
    $s = $v | Sort-Object; $n = $s.Count
    $med = if ($n % 2 -eq 1) { $s[[int](($n-1)/2)] } else { ($s[$n/2-1]+$s[$n/2])/2 }
    "{0,-34} med={1,7:N1} min={2,7:N1} max={3,7:N1}" -f $label, $med, $s[0], $s[$n-1]
}

Cleanup
& $Psmux -L $Ns new-session -d -s p 2>&1 | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 15000) { & $Psmux -L $Ns has-session -t p 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 20 }
Start-Sleep -Milliseconds 800
$port = [int]((Get-Content "$DataDir\$($Ns)__p.port" -Raw).Trim())
$key = (Get-Content "$DataDir\$($Ns)__p.key" -Raw).Trim()
Write-Host "session up, port=$port  gap between calls: ${GapMs}ms" -ForegroundColor Cyan

Write-Host ""
Write-Host "--- per sample: connect+AUTH+new-window+reply (no process spawn) ---" -ForegroundColor Yellow
$nw = @()
for ($i = 0; $i -lt $N; $i++) {
    $s = [Diagnostics.Stopwatch]::StartNew()
    $null = OneShot $port $key "new-window -t p"
    $s.Stop(); $nw += $s.Elapsed.TotalMilliseconds
    if ($GapMs -gt 0) { Start-Sleep -Milliseconds $GapMs }
}
Write-Host (Seq $nw)
Write-Host (Summ "new-window (wire, no spawn)" $nw)

Write-Host ""
Write-Host "--- per sample: connect+AUTH+list-sessions+reply (floor) ---" -ForegroundColor Yellow
$ls = @()
for ($i = 0; $i -lt $N; $i++) {
    $s = [Diagnostics.Stopwatch]::StartNew()
    $null = OneShot $port $key "list-sessions"
    $s.Stop(); $ls += $s.Elapsed.TotalMilliseconds
}
Write-Host (Seq $ls)
Write-Host (Summ "list-sessions (wire floor)" $ls)

Write-Host ""
Write-Host "--- per sample: full CLI psmux new-window ---" -ForegroundColor Yellow
$cli = @()
for ($i = 0; $i -lt $N; $i++) {
    $s = [Diagnostics.Stopwatch]::StartNew()
    & $Psmux -L $Ns new-window -t p 2>&1 | Out-Null
    $s.Stop(); $cli += $s.Elapsed.TotalMilliseconds
    if ($GapMs -gt 0) { Start-Sleep -Milliseconds $GapMs }
}
Write-Host (Seq $cli)
Write-Host (Summ "new-window (full CLI)" $cli)

Write-Host ""
Write-Host "--- per sample: psmux -V (process start only) ---" -ForegroundColor Yellow
$v = @()
for ($i = 0; $i -lt $N; $i++) {
    $s = [Diagnostics.Stopwatch]::StartNew(); & $Psmux -V | Out-Null; $s.Stop(); $v += $s.Elapsed.TotalMilliseconds
}
Write-Host (Seq $v)
Write-Host (Summ "psmux -V" $v)

Write-Host ""
Write-Host "--- per sample: psmux has-session (CLI, no creation) ---" -ForegroundColor Yellow
$hs = @()
for ($i = 0; $i -lt $N; $i++) {
    $s = [Diagnostics.Stopwatch]::StartNew(); & $Psmux -L $Ns has-session -t p 2>&1 | Out-Null; $s.Stop(); $hs += $s.Elapsed.TotalMilliseconds
}
Write-Host (Seq $hs)
Write-Host (Summ "psmux has-session (full CLI)" $hs)

Write-Host ""
Write-Host "--- baselines ---" -ForegroundColor Yellow
$b = @(); for ($i = 0; $i -lt $N; $i++) { $s = [Diagnostics.Stopwatch]::StartNew(); & cmd.exe /c exit | Out-Null; $s.Stop(); $b += $s.Elapsed.TotalMilliseconds }
Write-Host (Summ "cmd.exe /c exit" $b)
$b = @(); for ($i = 0; $i -lt $N; $i++) { $s = [Diagnostics.Stopwatch]::StartNew(); & pwsh -NoProfile -Command exit | Out-Null; $s.Stop(); $b += $s.Elapsed.TotalMilliseconds }
Write-Host (Summ "pwsh -NoProfile -Command exit" $b)

Cleanup
Write-Host "done."
