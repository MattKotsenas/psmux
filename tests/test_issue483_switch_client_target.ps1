# Issue #483: switch-client -t with window/pane-scoped targets was accepted (exit 0)
# but silently ignored; nonexistent targets also exited 0. This proves that
# switch-client -t session:window / @window / %pane now actually selects that
# window/pane for the attached client, and that an unresolvable target reports an
# error (non-zero exit).
#
# The command is driven over the exact server protocol the CLI uses from inside a
# pane (AUTH / TARGET <full> / switch-client) so routing is deterministic.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$S = "test_issue483"
$script:pass = 0; $script:fail = 0
function P($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3
& $PSMUX new-window -t $S -n two pwsh -NoProfile; Start-Sleep -Seconds 2
$proc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$S -PassThru
Start-Sleep -Seconds 4

function Send-Cmd([string]$full, [string]$command) {
  $port = (Get-Content "$psmuxDir\$S.port" -Raw).Trim()
  $key  = (Get-Content "$psmuxDir\$S.key" -Raw).Trim()
  $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
  $tcp.NoDelay = $true; $st = $tcp.GetStream(); $st.ReadTimeout = 3000
  $w = [System.IO.StreamWriter]::new($st); $r = [System.IO.StreamReader]::new($st)
  $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
  if ($full) { $w.Write("TARGET $full`n"); $w.Flush() }
  $w.Write("$command`n"); $w.Flush()
  $tcp.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
  $resp = ""; try { while (($line = $r.ReadLine()) -ne $null) { $resp += $line } } catch {}
  $tcp.Close(); return $resp
}
function ActiveIdx() { ((& $PSMUX list-windows -t $S -F '#{window_index}:#{window_active}') | Where-Object { $_ -match ':1$' }) -replace ':1','' }
function Reset() { Send-Cmd "${S}:1" "switch-client" | Out-Null; Start-Sleep -Milliseconds 900 }

Write-Host "`n=== Issue #483: switch-client window/pane targets ===" -ForegroundColor Cyan

Reset
Send-Cmd "${S}:0" "switch-client" | Out-Null; Start-Sleep -Milliseconds 1200
if ((ActiveIdx) -eq "0") { P "switch-client -t session:0 selected window 0" } else { F "session:window ignored (active=$(ActiveIdx))" }

Reset
Send-Cmd "@1" "switch-client" | Out-Null; Start-Sleep -Milliseconds 1200
if ((ActiveIdx) -eq "0") { P "switch-client -t @1 selected window 0" } else { F "@window ignored (active=$(ActiveIdx))" }

Reset
Send-Cmd "%1" "switch-client" | Out-Null; Start-Sleep -Milliseconds 1200
if ((ActiveIdx) -eq "0") { P "switch-client -t %1 selected the pane's window (0)" } else { F "%pane ignored (active=$(ActiveIdx))" }

Reset
$before = ActiveIdx
$r = Send-Cmd "${S}:9" "switch-client"; Start-Sleep -Milliseconds 800
if ($r -match "ERROR") { P "nonexistent target returns ERROR" } else { F "expected ERROR, got '$r'" }
if ((ActiveIdx) -eq $before) { P "active window unchanged on bad target" } else { F "bad target changed the active window" }

# CLI-level exit code (single-session routing resolves to this server)
& $PSMUX switch-client -t "${S}:9" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { P "CLI exits non-zero on unresolvable target" } else { F "CLI exited 0 on bad target" }
& $PSMUX switch-client -t "${S}:0" 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { P "CLI exits 0 on valid target" } else { F "CLI exited non-zero on valid target" }

Write-Host "`n=== Results: Passed=$($script:pass) Failed=$($script:fail) ===" -ForegroundColor Cyan
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
& $PSMUX kill-session -t $S 2>&1 | Out-Null
exit $script:fail
