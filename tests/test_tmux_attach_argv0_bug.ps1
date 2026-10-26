# Regression test: 'tmux a' (no -t, no positional) must NOT treat argv[0]
# (the exe path) as the session name.
# Historical bug: `tmux a` failed with "can't find session '...\tmux.exe'".
# That bug is FIXED, so a foreground `& $tmux a` now attaches and stays
# attached as a live TUI, which used to hang this script forever. The check
# therefore runs the attach in ITS OWN window via Start-Process:
#   [PASS] a client attaches to s0 within ~15s, proving argv[0] was not
#          mistaken for a session name
#   [FAIL] the 'tmux a' process exits on its own without ever attaching,
#          which is the old argv[0] failure pattern coming back
$ErrorActionPreference = "Continue"
$tmux = "$env:USERPROFILE\.cargo\bin\tmux.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$fail = 0

# Cleanup (scoped to tmux/psmux/pmux only)
Get-Process tmux,psmux,pmux -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 1
# Control files only. A bare "$psmuxDir\*" hits the plugins\ and servers\
# SUBDIRECTORIES, and Remove-Item without -Recurse then blocks forever on an
# interactive "directory not empty" confirmation prompt (-EA SilentlyContinue
# does not suppress confirmations). That prompt is what hung this suite
# before a single line of output.
Remove-Item "$psmuxDir\*.port","$psmuxDir\*.key","$psmuxDir\*.pid","$psmuxDir\*.sid" -Force -EA SilentlyContinue

Write-Host "[1] tmux -V"
& $tmux -V

Write-Host "[2] start detached session 's0'"
Start-Process -FilePath $tmux -ArgumentList "new-session","-d","-s","s0" -WindowStyle Hidden | Out-Null
$s0Up = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 12000) {
    $ls = & $tmux ls 2>&1 | Out-String
    if ($ls -match '(?m)^s0[:\s]') { $s0Up = $true; break }
    Start-Sleep -Milliseconds 300
}

Write-Host "[3] tmux ls"
& $tmux ls
if (-not $s0Up) {
    Write-Host "[FAIL] session s0 never came up; cannot test 'tmux a'" -ForegroundColor Red
    exit 1
}

Write-Host "[4] tmux a (no args) launched in its own window"
$p = Start-Process -FilePath $tmux -ArgumentList "a" -PassThru
$attached = $false
$exitedEarly = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 15000) {
    $att = (& $tmux display-message -t s0 -p '#{session_attached}' 2>&1) -join ''
    if ($att.Trim() -match '^[1-9]\d*$') { $attached = $true; break }
    $clients = & $tmux list-clients -t s0 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $clients.Trim().Length -gt 0 -and $clients -notmatch "error|can't find|no such") {
        $attached = $true; break
    }
    if ($p.HasExited) { $exitedEarly = $true; break }
    Start-Sleep -Milliseconds 400
}

if ($attached) {
    Write-Host "[PASS] 'tmux a' attached a client to s0; argv[0] was not treated as a session name" -ForegroundColor Green
} elseif ($exitedEarly) {
    Write-Host "[FAIL] 'tmux a' exited on its own (exit code $($p.ExitCode)) without attaching. The old argv[0] bug (can't find session '...tmux.exe') is likely back." -ForegroundColor Red
    $fail++
} else {
    Write-Host "[FAIL] no client attached to s0 within 15s and the attach process is still running" -ForegroundColor Red
    $fail++
}

# Teardown: never leave the attach process or the session behind
& $tmux kill-session -t s0 2>&1 | Out-Null
if ($p -and -not $p.HasExited) {
    $null = $p.WaitForExit(5000)
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -EA SilentlyContinue }
}

exit $fail
