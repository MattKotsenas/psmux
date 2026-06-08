# Deterministic end-to-end verification of #363 fix WITHOUT the flaky console
# injector. Drives the singular send-key path (the exact path the attached client
# uses for real Ctrl+<letter>) and verifies behavior in nvim and PSReadLine.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$NVIM  = "C:\PROGRA~1\Neovim\bin\nvim.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$pass = 0; $fail = 0
function Ok($m){ $script:pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad($m){ $script:fail++; Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Cap($s){ (& $PSMUX capture-pane -t $s -p 2>&1 | Out-String) }

# ---------------- nvim: singular send-key C-w + s must SPLIT (not insert) ----------------
$s = "v363e_nvim"
& $PSMUX kill-session -t $s 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX new-session -d -s $s -x 120 -y 40 "$NVIM --clean" 2>&1 | Out-Null
Start-Sleep -Seconds 4
& $PSMUX has-session -t $s 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FATAL] nvim session not created" -ForegroundColor Red; exit 2 }

Write-Host "`n=== nvim <C-w>s via singular send-key (the buggy path) ===" -ForegroundColor Cyan
& $PSMUX send-key C-w -t $s 2>&1 | Out-Null   # NOTE: send-key (singular) - client path
Start-Sleep -Milliseconds 400
& $PSMUX send-key s   -t $s 2>&1 | Out-Null
Start-Sleep -Milliseconds 900
$cap = Cap $s
$insert = $cap -match "-- INSERT --"
# readback winnr via send-keys -l (literal) so '$' is sent verbatim
$wcFile = "$env:TEMP\v363e_wc.txt"; Remove-Item $wcFile -Force -EA SilentlyContinue
$fp = ($wcFile -replace '\\','/')
& $PSMUX send-keys -t $s Escape 2>&1 | Out-Null; Start-Sleep -Milliseconds 200
& $PSMUX send-keys -t $s -l ":call writefile([winnr('`$')],'$fp')" 2>&1 | Out-Null
& $PSMUX send-keys -t $s Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
$wc = if (Test-Path $wcFile) { (Get-Content $wcFile -Raw).Trim() } else { "<none>" }
Write-Host "  insert=$insert  winnr('`$')=$wc"
if (-not $insert -and $wc -eq "2") { Ok "nvim: single send-key C-w => <C-w>s SPLIT (winnr=2), no insert" }
elseif ($insert) { Bad "nvim: insert mode => Ctrl+W STILL doubling (<C-w><C-w>s)" }
else { Bad "nvim: no insert but winnr=$wc (expected 2)" }

# control: confirm pre-fix symptom detector is valid by checking a bare 's' DOES insert
& $PSMUX send-keys -t $s Escape 2>&1 | Out-Null; Start-Sleep -Milliseconds 200
& $PSMUX send-keys -t $s -l ":only" 2>&1 | Out-Null; & $PSMUX send-keys -t $s Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $PSMUX send-key s -t $s 2>&1 | Out-Null   # bare 's' in normal mode = substitute = insert
Start-Sleep -Milliseconds 500
$capS = Cap $s
if ($capS -match "-- INSERT --") { Ok "control: bare 's' DOES enter insert (detector valid)" }
else { Bad "control: bare 's' did not insert - detector questionable" }
& $PSMUX kill-session -t $s 2>&1 | Out-Null
Get-Process nvim -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue

# ---------------- PSReadLine: singular send-key C-w deletes ONE word ----------------
$s = "v363e_psr"
& $PSMUX kill-session -t $s 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX new-session -d -s $s -x 120 -y 30 "pwsh -NoLogo -NoProfile" 2>&1 | Out-Null
Start-Sleep -Seconds 2
for ($i=0;$i -lt 20;$i++){ Start-Sleep -Milliseconds 400; if ((Cap $s) -match 'PS\s'){break} }
Write-Host "`n=== PSReadLine Ctrl+W via singular send-key ===" -ForegroundColor Cyan
& $PSMUX send-keys -t $s -l "hello world" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$before = (Cap $s -split "`n" | Where-Object { $_ -match 'PS\s' } | Select-Object -Last 1)
& $PSMUX send-key C-w -t $s 2>&1 | Out-Null
Start-Sleep -Milliseconds 700
$after = (Cap $s -split "`n" | Where-Object { $_ -match 'PS\s' } | Select-Object -Last 1)
Write-Host "  before='$($before.Trim())'"
Write-Host "  after ='$($after.Trim())'"
if ($before -match 'hello world' -and $after -match 'hello\s*$' -and $after -notmatch 'world') { Ok "PSReadLine: Ctrl+W deleted ONE word; 'hello ' remains" }
elseif ($after -notmatch 'hello') { Bad "PSReadLine: deleted BOTH words - double STILL present" }
else { Bad "PSReadLine inconclusive before='$before' after='$after'" }

# ---------------- Ctrl+C interrupt still works ----------------
Write-Host "`n=== Ctrl+C interrupt via singular send-key ===" -ForegroundColor Cyan
& $PSMUX send-keys -t $s -l "while(`$true){Start-Sleep -Milliseconds 200}" 2>&1 | Out-Null
& $PSMUX send-keys -t $s Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX send-key C-c -t $s 2>&1 | Out-Null
Start-Sleep -Milliseconds 1200
& $PSMUX send-keys -t $s -l "echo BACKALIVE" 2>&1 | Out-Null
& $PSMUX send-keys -t $s Enter 2>&1 | Out-Null
Start-Sleep -Milliseconds 1500
$cc = Cap $s
if ($cc -match "BACKALIVE") { Ok "Ctrl+C interrupted loop; shell responsive" }
else { Bad "Ctrl+C did not return responsive prompt" }
& $PSMUX kill-session -t $s 2>&1 | Out-Null

Write-Host "`n=== RESULT: $pass passed, $fail failed ===" -ForegroundColor $(if($fail){"Red"}else{"Green"})
exit $fail
