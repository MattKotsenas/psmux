# Issue #555: switch-client with an unresolvable window/pane on a CROSS-session
# target exits 0 (SWITCH emitted before validation), while the same bad target
# within the current session correctly errors (#483). tmux 3.4 errors and does
# not switch in both cases.
# Harness mirrors test_issue483_switch_client_cross_session.ps1.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$SRC = "t555src"; $DST = "t555dst"
$script:pass = 0; $script:fail = 0
function P($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

foreach ($s in @($SRC,$DST)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
Start-Sleep -Milliseconds 800
& $PSMUX new-session -d -s $SRC; Start-Sleep -Seconds 3
& $PSMUX new-session -d -s $DST; Start-Sleep -Seconds 3
& $PSMUX new-window -t $DST -n dwin1 pwsh -NoProfile; Start-Sleep -Seconds 2
& $PSMUX new-window -t $SRC -n swin1 pwsh -NoProfile; Start-Sleep -Seconds 2

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
function SrcAttached() { (& $PSMUX display-message -p -t $SRC '#{session_attached}' 2>&1 | Out-String).Trim() }
function DstAttached() { (& $PSMUX display-message -p -t $DST '#{session_attached}' 2>&1 | Out-String).Trim() }

Write-Host "`n=== Issue #555 repro ===" -ForegroundColor Cyan
if ((SrcAttached) -eq "1") { P "setup: client attached to $SRC" }
else { F "setup: client not attached to $SRC"; }

# --- Control 1: same-session bad window errors (per #483) ---
$r = Send-ToSrc "${SRC}:99"; Start-Sleep -Seconds 1
if ($r -match "ERROR" -and $r -match "can't find window") { P "control: same-session ${SRC}:99 -> ERROR ($r)" }
else { F "control: same-session ${SRC}:99 resp='$r' (expected ERROR)" }
if ((SrcAttached) -eq "1" -and (DstAttached) -ne "1") { P "control: client stayed on $SRC" }
else { F "control: client moved (src=$(SrcAttached) dst=$(DstAttached))" }

# --- A: CROSS-session bad window via raw TCP ---
$r = Send-ToSrc "${DST}:99"; Start-Sleep -Seconds 2
$srcA = SrcAttached; $dstA = DstAttached
if ($r -match "ERROR" -and $r -match "can't find window") { P "A: cross-session ${DST}:99 -> ERROR ($r)" }
else { F "BUG A: cross-session ${DST}:99 resp='$r' (expected ERROR can't find window: 99)" }
if ($srcA -eq "1" -and $dstA -ne "1") { P "A2: client stayed on $SRC (no switch)" }
else { F "BUG A2: client switched anyway (src=$srcA dst=$dstA)" }

# recover if the client moved
if ((DstAttached) -eq "1") { & $PSMUX switch-client -t "${SRC}:0" 2>&1 | Out-Null; Start-Sleep -Seconds 2 }

# --- B: CROSS-session bad @id via raw TCP ---
$r = Send-ToSrc "${DST}:@99"; Start-Sleep -Seconds 2
$srcA = SrcAttached; $dstA = DstAttached
if ($r -match "ERROR" -and $r -match "can't find window") { P "B: cross-session ${DST}:@99 -> ERROR ($r)" }
else { F "BUG B: cross-session ${DST}:@99 resp='$r'" }
if ($srcA -eq "1" -and $dstA -ne "1") { P "B2: client stayed on $SRC" }
else { F "BUG B2: client switched anyway (src=$srcA dst=$dstA)" }
if ((DstAttached) -eq "1") { & $PSMUX switch-client -t "${SRC}:0" 2>&1 | Out-Null; Start-Sleep -Seconds 2 }

# --- C: nonexistent destination session via raw TCP ---
$r = Send-ToSrc "t555nosuch:0"; Start-Sleep -Seconds 1
if ($r -match "ERROR" -and $r -match "can't find session") { P "C: nonexistent session -> ERROR ($r)" }
else { F "BUG C: nonexistent session resp='$r' (expected ERROR can't find session)" }
if ((SrcAttached) -eq "1") { P "C2: client stayed on $SRC" }
else { F "BUG C2: client detached/moved" }

# --- D: CLI path exit code for cross-session bad window ---
$out = & $PSMUX switch-client -t "${DST}:99" 2>&1
$rcD = $LASTEXITCODE
Start-Sleep -Seconds 1
if ($rcD -ne 0) { P "D: CLI switch-client -t ${DST}:99 rc=$rcD ($out)" }
else { F "BUG D: CLI switch-client -t ${DST}:99 rc=0 out='$out'" }
if ((SrcAttached) -eq "1" -and (DstAttached) -ne "1") { P "D2: client stayed on $SRC" }
else { F "BUG D2: client moved (src=$(SrcAttached) dst=$(DstAttached))" }
if ((DstAttached) -eq "1") { & $PSMUX switch-client -t "${SRC}:0" 2>&1 | Out-Null; Start-Sleep -Seconds 2 }

# --- Positive: valid cross-session switch still works (must not regress #483) ---
$r = Send-ToSrc "${DST}:1"; Start-Sleep -Seconds 2
$dstWin = ((& $PSMUX list-windows -t $DST -F '#{window_index}:#{window_active}') | Where-Object { $_ -match ':1$' }) -replace ':1',''
if ($r -match "OK" -and (DstAttached) -eq "1" -and $dstWin -eq "1") { P "positive: valid ${DST}:1 switched, window 1 active" }
else { F "positive: resp='$r' dstAttached=$(DstAttached) dstWin=$dstWin" }

Write-Host "`n=== Results: Passed=$($script:pass) Failed=$($script:fail) ===" -ForegroundColor Cyan
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
foreach ($s in @($SRC,$DST)) { & $PSMUX kill-session -t $s 2>&1 | Out-Null }
exit $script:fail
