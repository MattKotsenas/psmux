# Issue #413: numeric prefixes for copy-mode-vi motions have no effect.
#
# Proves that in copy-mode-vi a numeric prefix repeats the motion N times:
#   5j -> down 5, 3k -> up 3, 10j -> down 10, 3l -> right 3, etc.
# Injects REAL keystrokes with WriteConsoleInput (the only path that exercises
# the send-text -> handle_copy_mode_char route the fix touches) and reads the
# copy-mode cursor row/col from a fresh dump-state snapshot after each burst.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$INJ = "$env:TEMP\psmux_injector.exe"
$S = "issue413vi"
$script:Pass = 0
$script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

# Compile injector if missing
if (-not (Test-Path $INJ)) {
  $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  & $csc /nologo /optimize /out:$INJ "$PSScriptRoot\injector.cs" 2>&1 | Out-Null
}

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$S -PassThru
Start-Sleep -Seconds 4
& $PSMUX set-option -g mode-keys vi 2>&1 | Out-Null
for ($i=1; $i -le 40; $i++) { & $PSMUX send-keys -t $S "echo LINE_$i" Enter 2>&1 | Out-Null }
Start-Sleep -Seconds 2

$port = (Get-Content "$psmuxDir\$S.port" -Raw).Trim()
$key  = (Get-Content "$psmuxDir\$S.key" -Raw).Trim()

# Fresh non-persistent dump each call = no stale pipeline frames
function Get-State {
  $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
  $tcp.NoDelay=$true; $tcp.ReceiveTimeout=4000
  $st=$tcp.GetStream(); $w=[System.IO.StreamWriter]::new($st); $r=[System.IO.StreamReader]::new($st)
  $w.Write("AUTH $key`n"); $w.Flush(); $null=$r.ReadLine()
  $w.Write("dump-state`n"); $w.Flush()
  $best=$null
  for($j=0;$j -lt 300;$j++){ try{$line=$r.ReadLine()}catch{break}; if($null -eq $line){break}; if($line -ne "NC" -and $line.Length -gt 100){$best=$line; break} }
  $tcp.Close()
  if($best){ $jj=$best|ConvertFrom-Json; return @{row=[int]$jj.layout.copy_cursor_row; col=[int]$jj.layout.copy_cursor_col; copy=$jj.layout.copy_mode} }
  return $null
}

Write-Host "`n=== Issue #413: numeric prefix in copy-mode-vi ===" -ForegroundColor Cyan

& $PSMUX copy-mode -t $S 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$c0 = Get-State
if (-not $c0.copy) { Write-Fail "could not enter copy mode"; & $PSMUX kill-session -t $S 2>&1|Out-Null; try{Stop-Process -Id $proc.Id -Force}catch{}; exit 1 }
Write-Host "  entered copy mode at row=$($c0.row) col=$($c0.col)"

# Helper: inject a burst, return row delta (signed, positive = down)
function Move-And-Delta($keys) {
  $b = (Get-State).row
  & $INJ $proc.Id $keys | Out-Null
  Start-Sleep -Seconds 1
  $a = (Get-State).row
  return @{ before=$b; after=$a.ToString(); delta=($a - $b) }
}
function Col-And-Delta($keys) {
  $b = (Get-State).col
  & $INJ $proc.Id $keys | Out-Null
  Start-Sleep -Seconds 1
  $a = (Get-State).col
  return ($a - $b)
}

# Move up into the middle so both directions have room
& $INJ $proc.Id "kkkkkkkkkkkkkkk" | Out-Null
Start-Sleep -Seconds 1

# --- Baseline: single motion still moves exactly 1 ---
$r = Move-And-Delta "j"
if ($r.delta -eq 1) { Write-Pass "plain 'j' moves down 1" } else { Write-Fail "plain 'j' moved $($r.delta), expected 1" }

# --- 5j down 5 ---
$r = Move-And-Delta "5j"
if ($r.delta -eq 5) { Write-Pass "'5j' moves down 5" } else { Write-Fail "'5j' moved $($r.delta), expected 5" }

# --- 3k up 3 ---
$r = Move-And-Delta "3k"
if ($r.delta -eq -3) { Write-Pass "'3k' moves up 3" } else { Write-Fail "'3k' moved $($r.delta), expected -3" }

# --- 10j down 10 (two-digit count) ---
$r = Move-And-Delta "10j"
if ($r.delta -eq 10) { Write-Pass "'10j' moves down 10 (two-digit count)" } else { Write-Fail "'10j' moved $($r.delta), expected 10" }

# --- 7k up 7 ---
$r = Move-And-Delta "7k"
if ($r.delta -eq -7) { Write-Pass "'7k' moves up 7" } else { Write-Fail "'7k' moved $($r.delta), expected -7" }

# --- horizontal: go to line start, then 4l right 4 ---
& $INJ $proc.Id "0" | Out-Null   # line start
Start-Sleep -Milliseconds 700
$d = Col-And-Delta "4l"
if ($d -eq 4) { Write-Pass "'4l' moves right 4 columns" } else { Write-Fail "'4l' moved $d cols, expected 4" }

# --- 2h left 2 ---
$d = Col-And-Delta "2h"
if ($d -eq -2) { Write-Pass "'2h' moves left 2 columns" } else { Write-Fail "'2h' moved $d cols, expected -2" }

$tcp = $null
& $PSMUX kill-session -t $S 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results: $($script:Pass) passed, $($script:Fail) failed ===" -ForegroundColor Cyan
exit $script:Fail
