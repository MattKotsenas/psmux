# Repro for issue #363: <C-w>s in nvim enters insert mode instead of splitting.
# Hypothesis: Ctrl+W is swallowed by psmux and never reaches nvim, so only the
# following 's' reaches nvim. In nvim normal mode 's' = substitute = INSERT mode.
# Discriminator:
#   BUG  -> pane shows "-- INSERT --"  (Ctrl+W lost, only 's' delivered)
#   OK   -> pane shows two windows / winnr('$')==2, NO "-- INSERT --"
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$NVIM  = "C:\PROGRA~1\Neovim\bin\nvim.exe"   # 8.3 short path - no spaces
$SESSION = "repro363"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
    Get-Process nvim -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
}

Cleanup
Write-Host "=== Launching psmux attached session running nvim --clean ===" -ForegroundColor Cyan
# Launch a real visible psmux window whose initial command is nvim
$proc = Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$SESSION,"$NVIM --clean") -PassThru
Start-Sleep -Seconds 6

# Confirm session exists
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FATAL] session not created" -ForegroundColor Red; exit 2 }

# Capture baseline (nvim should be loaded - blank buffer with ~ lines)
$base = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
Write-Host "--- Baseline pane (nvim loaded) ---" -ForegroundColor DarkGray
Write-Host $base
Write-Host "--- end baseline ---" -ForegroundColor DarkGray

# Make sure we are in NORMAL mode first (press ESC), then inject <C-w>s
& $injectorExe $proc.Id "{ESC}{SLEEP:400}^w{SLEEP:400}s"
Start-Sleep -Seconds 2

$after = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
Write-Host "`n--- Pane AFTER injecting <C-w>s ---" -ForegroundColor Yellow
Write-Host $after
Write-Host "--- end after ---" -ForegroundColor Yellow

# Verdict
$insert = $after -match "-- INSERT --"
if ($insert) {
    Write-Host "`n[BUG REPRODUCED] nvim shows '-- INSERT --' => Ctrl+W was SWALLOWED, only 's' reached nvim." -ForegroundColor Red
} else {
    Write-Host "`n[NO INSERT MODE] Ctrl+W appears to have reached nvim (no substitute-insert)." -ForegroundColor Green
}

# Independent confirmation via Ex command writing window count to a file.
# Press ESC to leave any insert mode, then run :call writefile(...).
$wcFile = "$env:TEMP\repro363_wincount.txt"
Remove-Item $wcFile -Force -EA SilentlyContinue
# ESC out, then type the ex command. Use injector symbol support.
& $injectorExe $proc.Id "{ESC}{SLEEP:300}:call writefile([winnr('$')],'$($wcFile -replace '\\','/')'){ENTER}"
Start-Sleep -Seconds 2
$wc = if (Test-Path $wcFile) { (Get-Content $wcFile -Raw).Trim() } else { "<no-file>" }
Write-Host "`nwinnr('`$') after <C-w>s = $wc  (1 = split FAILED/bug, 2 = split worked)" -ForegroundColor Cyan

Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
Write-Host "INSERT mode after <C-w>s : $insert"
Write-Host "Window count after <C-w>s: $wc"
