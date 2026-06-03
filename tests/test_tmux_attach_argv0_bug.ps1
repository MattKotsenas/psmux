# Repro: 'tmux a' (no -t, no positional) treats argv[0] (exe path) as session name
$ErrorActionPreference = "Continue"
$tmux = "$env:USERPROFILE\.cargo\bin\tmux.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"

# Cleanup
Get-Process tmux,psmux,pmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 1
Remove-Item "$psmuxDir\*" -Force -EA SilentlyContinue

Write-Host "[1] tmux -V"
& $tmux -V
Write-Host "[2] start session 's0'"
Start-Process -FilePath $tmux -ArgumentList "new-session","-d","-s","s0" -WindowStyle Hidden | Out-Null
Start-Sleep 4
Write-Host "[3] tmux ls"
& $tmux ls
Write-Host "[4] tmux a (no args)"
$out = & $tmux a 2>&1 | Out-String
Write-Host "exit=$LASTEXITCODE"
Write-Host "OUTPUT:"
Write-Host $out
if ($out -match "can't find session '.*tmux\.exe'") {
    Write-Host "[BUG REPRODUCED] argv[0] used as session name" -ForegroundColor Red
    exit 1
} elseif ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] attached cleanly" -ForegroundColor Green
    exit 0
} else {
    Write-Host "[OTHER] exit=$LASTEXITCODE (may be benign console-attach issue when stdin redirected)" -ForegroundColor Yellow
    # If exit code is non-zero but no argv0 leakage, the bug is NOT this one
    exit 0
}
