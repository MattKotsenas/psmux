# probe_cli_gap.ps1 — the CLI `psmux new-window` costs far more than
# (psmux.exe process start) + (the same verb sent over a raw socket). This
# isolates where the gap is by comparing CLI verbs whose wire costs are known,
# and by proxying the CLI's own socket so every line it sends is timestamped.
param([string]$Ns = "gap$PID", [int]$N = 12, [string]$Psmux = "")
$ErrorActionPreference = "Continue"
if (-not $Psmux) { $Psmux = Join-Path (Split-Path -Parent $PSScriptRoot) "target\release\psmux.exe" }
$Psmux = (Resolve-Path $Psmux).Path
$DataDir = Join-Path $env:USERPROFILE ".psmux"

function Cleanup {
    param([string]$n)
    try { & $Psmux -L $n kill-server 2>&1 | Out-Null } catch {}
    Start-Sleep -Milliseconds 200
    Get-ChildItem "$DataDir\$($n)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
function Med { param([double[]]$v) $s = $v | Sort-Object; $n = $s.Count; if ($n % 2 -eq 1) { $s[[int](($n-1)/2)] } else { ($s[$n/2-1]+$s[$n/2])/2 } }
function Seq { param([double[]]$v) return (($v | ForEach-Object { "{0,7:N1}" -f $_ }) -join "") }

Cleanup $Ns
& $Psmux -L $Ns new-session -d -s p 2>&1 | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 15000) { & $Psmux -L $Ns has-session -t p 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Milliseconds 20 }
Start-Sleep -Milliseconds 800

Write-Host ""
Write-Host "=== CLI verb costs (each includes one whole psmux.exe process start) ===" -ForegroundColor Yellow
$verbs = @(
    @{ n = "-V (no server contact)";        a = @("-V") },
    @{ n = "has-session";                   a = @("-L", $Ns, "has-session", "-t", "p") },
    @{ n = "list-sessions";                 a = @("-L", $Ns, "list-sessions") },
    @{ n = "display-message -p";            a = @("-L", $Ns, "display-message", "-p", "x") },
    @{ n = "rename-window (mutates)";       a = @("-L", $Ns, "rename-window", "-t", "p", "zz") },
    @{ n = "select-window (mutates)";       a = @("-L", $Ns, "select-window", "-t", "p:0") },
    @{ n = "new-window";                    a = @("-L", $Ns, "new-window", "-t", "p") },
    @{ n = "new-window -d";                 a = @("-L", $Ns, "new-window", "-d", "-t", "p") },
    @{ n = "split-window";                  a = @("-L", $Ns, "split-window", "-t", "p") },
    @{ n = "kill-window (destroys)";        a = @("-L", $Ns, "kill-window", "-t", "p") }
)
$res = @{}
foreach ($v in $verbs) {
    $t = @()
    for ($i = 0; $i -lt $N; $i++) {
        $s = [Diagnostics.Stopwatch]::StartNew()
        & $Psmux @($v.a) 2>&1 | Out-Null
        $s.Stop(); $t += $s.Elapsed.TotalMilliseconds
    }
    $res[$v.n] = $t
    Write-Host ("  {0,-28} med={1,7:N1}  min={2,7:N1}   {3}" -f $v.n, (Med $t), ($t | Measure-Object -Minimum).Minimum, (Seq $t)) -ForegroundColor Cyan
}

# ---------------------------------------------------------------- proxy trace
# Point a second namespace's registry files at a logging proxy so the real CLI
# connects through it. Every line it sends and receives is timestamped relative
# to the moment the CLI process was launched.
Write-Host ""
Write-Host "=== PROXY TRACE of one `psmux new-window` CLI invocation ===" -ForegroundColor Yellow
$realPort = [int]((Get-Content "$DataDir\$($Ns)__p.port" -Raw).Trim())
$key = (Get-Content "$DataDir\$($Ns)__p.key" -Raw).Trim()

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$proxyPort = $listener.LocalEndpoint.Port
$pns = "$($Ns)x"
foreach ($ext in @("port", "key", "pid", "sid")) {
    $src = "$DataDir\$($Ns)__p.$ext"
    if (Test-Path $src) { Copy-Item $src "$DataDir\$($pns)__p.$ext" -Force }
}
[IO.File]::WriteAllText("$DataDir\$($pns)__p.port", "$proxyPort")

foreach ($verb in @("new-window -t p", "rename-window -t p qq")) {
    $log = New-Object System.Collections.ArrayList
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $args2 = @("-L", $pns) + $verb.Split(" ")
    $proc = Start-Process -FilePath $Psmux -ArgumentList $args2 -PassThru -WindowStyle Hidden -RedirectStandardOutput "$env:TEMP\pxout.txt" -RedirectStandardError "$env:TEMP\pxerr.txt"

    $accepted = $listener.AcceptTcpClient()
    [void]$log.Add(("{0,8:N1}  CLI connected" -f $sw.Elapsed.TotalMilliseconds))
    $accepted.NoDelay = $true
    $up = New-Object System.Net.Sockets.TcpClient
    $up.NoDelay = $true
    $up.Connect("127.0.0.1", $realPort)

    $cs = $accepted.GetStream(); $us = $up.GetStream()
    $cr = New-Object System.IO.StreamReader($cs); $cw = New-Object System.IO.StreamWriter($cs); $cw.AutoFlush = $true
    $ur = New-Object System.IO.StreamReader($us); $uw = New-Object System.IO.StreamWriter($us); $uw.AutoFlush = $true

    # pump server -> client on a runspace-free background thread
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($ur, $cw, $sw, $log)
        try { while ($true) { $l = $ur.ReadLine(); if ($null -eq $l) { break }
            [void]$log.Add(("{0,8:N1}  <= {1}" -f $sw.Elapsed.TotalMilliseconds, $l.Substring(0, [Math]::Min(70, $l.Length))))
            $cw.WriteLine($l) } } catch {}
        [void]$log.Add(("{0,8:N1}  <= EOF" -f $sw.Elapsed.TotalMilliseconds))
    }).AddArgument($ur).AddArgument($cw).AddArgument($sw).AddArgument($log)
    $h = $ps.BeginInvoke()

    try {
        while ($true) {
            $l = $cr.ReadLine()
            if ($null -eq $l) { [void]$log.Add(("{0,8:N1}  => EOF (client closed)" -f $sw.Elapsed.TotalMilliseconds)); break }
            [void]$log.Add(("{0,8:N1}  => {1}" -f $sw.Elapsed.TotalMilliseconds, $l.Substring(0, [Math]::Min(70, $l.Length))))
            $uw.WriteLine($l)
        }
    } catch {}
    $proc.WaitForExit(15000) | Out-Null
    [void]$log.Add(("{0,8:N1}  CLI process exited" -f $sw.Elapsed.TotalMilliseconds))
    Start-Sleep -Milliseconds 150
    try { $ps.Stop() } catch {}
    try { $accepted.Close(); $up.Close() } catch {}

    Write-Host ""
    Write-Host ("--- $verb ---") -ForegroundColor Magenta
    $log | ForEach-Object { Write-Host "   $_" }
}
$listener.Stop()
Get-ChildItem "$DataDir\$($pns)__*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Cleanup $Ns
Write-Host "done."
