# Issue #483 (follow-up): a cross-session switch-client target that also names a
# window/pane (session:window[.pane]) must land the re-attaching client on that
# window/pane, not on the destination's currently-active window. psmux runs one
# server per session, so the source server pre-selects the window/pane on the
# destination server before signalling the client to re-attach.
#
# NOTE: a BARE cross-session pane/window id (e.g. %5 with no session prefix) is
# intentionally NOT resolved across sessions: pane/window id spaces are per
# server, so an unqualified id is only meaningful within the current session.
# Use a session-qualified target for cross-session moves.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SRC = "test483src"; $DST = "test483dst"
$script:pass = 0; $script:fail = 0
function P($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

foreach ($s in @($SRC,$DST)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 800
& $PSMUX new-session -d -s $SRC; Start-Sleep -Seconds 3
& $PSMUX new-session -d -s $DST; Start-Sleep -Seconds 3
& $PSMUX new-window -t $DST -n dwin1 pwsh -NoProfile; Start-Sleep -Seconds 2
& $PSMUX split-window -h -t "${DST}:1" pwsh -NoProfile; Start-Sleep -Seconds 2
& $PSMUX select-window -t "${DST}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 800

$proc = Start-Process -FilePath $PSMUX -ArgumentList "attach","-t",$SRC -PassThru
Start-Sleep -Seconds 4

function Send-ToSrc([string]$full) {
  $port = (Get-Content "$psmuxDir\$SRC.port" -Raw).Trim()
  $key  = (Get-Content "$psmuxDir\$SRC.key" -Raw).Trim()
  $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
  $tcp.NoDelay = $true; $st = $tcp.GetStream(); $st.ReadTimeout = 3000
  $w = [System.IO.StreamWriter]::new($st); $r = [System.IO.StreamReader]::new($st)
  $w.Write("AUTH $key`n"); $w.Flush(); $null = $r.ReadLine()
  $w.Write("TARGET $full`n"); $w.Flush()
  $w.Write("switch-client`n"); $w.Flush()
  $tcp.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
  $resp=""; try { while (($l=$r.ReadLine()) -ne $null){ $resp+=$l } } catch {}
  $tcp.Close(); return $resp
}
function DstWin() { ((& $PSMUX list-windows -t $DST -F '#{window_index}:#{window_active}') | Where-Object { $_ -match ':1$' }) -replace ':1','' }
function DstWin1Pane() { ((& $PSMUX list-panes -t "${DST}:1" -F '#{pane_index}:#{pane_active}') | Where-Object { $_ -match ':1$' }) -replace ':1','' }
function ResetDst() { & $PSMUX select-window -t "${DST}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 600 }

Write-Host "`n=== Issue #483 cross-session window/pane selection ===" -ForegroundColor Cyan

# Case 1: session:window
ResetDst
$r = Send-ToSrc "${DST}:1"; Start-Sleep -Seconds 2
if ($r -match "OK" -and (DstWin) -eq "1") { P "cross-session session:window landed on window 1" }
else { F "resp='$r' dstWin=$(DstWin) (want 1)" }

# bring the client back to SRC for the next case
& $PSMUX switch-client -t $SRC 2>&1 | Out-Null; Start-Sleep -Seconds 2

# Case 2: session:window.pane
ResetDst
$r = Send-ToSrc "${DST}:1.1"; Start-Sleep -Seconds 2
$okWin = (DstWin) -eq "1"; $okPane = (DstWin1Pane) -eq "1"
if ($r -match "OK" -and $okWin -and $okPane) { P "cross-session session:window.pane landed on window 1 pane 1" }
else { F "resp='$r' dstWin=$(DstWin) dstPane=$(DstWin1Pane) (want win1 pane1)" }

# Case 3: the SAME session shape, session:window.pane where session is the
# client's own. tmux's cmd-switch-client sets the window's active pane and
# then the session's current window (cmd-switch-client.c:140-151) for every
# -t shape; case 2 above is the cross session half, this is the other half.
& $PSMUX switch-client -t $SRC 2>&1 | Out-Null; Start-Sleep -Seconds 2
& $PSMUX new-window -t $SRC -n swin1 pwsh -NoProfile; Start-Sleep -Seconds 2
& $PSMUX split-window -h -t "${SRC}:1" pwsh -NoProfile; Start-Sleep -Seconds 2
& $PSMUX select-pane -t "${SRC}:1.0" 2>&1 | Out-Null
& $PSMUX select-window -t "${SRC}:0" 2>&1 | Out-Null; Start-Sleep -Milliseconds 600
function SrcWin() { ((& $PSMUX list-windows -t $SRC -F '#{window_index}:#{window_active}') | Where-Object { $_ -match ':1$' }) -replace ':1','' }
function SrcWin1Pane() { ((& $PSMUX list-panes -t "${SRC}:1" -F '#{pane_index}:#{pane_active}') | Where-Object { $_ -match ':1$' }) -replace ':1','' }
$r = Send-ToSrc "${SRC}:1.1"; Start-Sleep -Seconds 2
$okWin = (SrcWin) -eq "1"; $okPane = (SrcWin1Pane) -eq "1"
if ($r -match "OK" -and $okWin -and $okPane) { P "same-session session:window.pane landed on window 1 pane 1" }
else { F "same-session resp='$r' srcWin=$(SrcWin) srcPane=$(SrcWin1Pane) (want win1 pane1)" }

Write-Host "`n=== Results: Passed=$($script:pass) Failed=$($script:fail) ===" -ForegroundColor Cyan
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
foreach ($s in @($SRC,$DST)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
exit $script:fail
