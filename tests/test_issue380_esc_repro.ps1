# Issue #380: bare <Esc> keypress not delivered to child under ConPTY WIN32_INPUT_MODE
# Reproduction / proof harness.
#
# Launches a REAL attached psmux window, runs esc_reader.py in the pane (which
# enables ENABLE_VIRTUAL_TERMINAL_INPUT like Neovim/Claude Code do), then
# injects a bare <Esc> keypress into psmux via WriteConsoleInput. Verifies
# whether the child's stdin actually received the 0x1b byte.
#
# BUG (pre-fix):  child log has NO "1b"  -> Esc swallowed by ConPTY parser.
# FIXED:          child log contains "1b" -> Esc delivered as a key event.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue380_esc"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$readerLog = "$env:TEMP\esc_reader_380.log"
$readerPy = (Resolve-Path "$PSScriptRoot\esc_reader.py").Path
$py = (Get-Command python -EA Stop).Source

$script:Pass = 0; $script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Get-Process psmux -EA SilentlyContinue | Where-Object { $_.Id -eq $script:procId } | Stop-Process -Force -EA SilentlyContinue
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Write-Host "`n=== Issue #380 Esc-delivery reproduction ===" -ForegroundColor Cyan
Write-Host "psmux: $PSMUX" -ForegroundColor DarkGray

Cleanup
Remove-Item $readerLog -Force -EA SilentlyContinue

# Launch a REAL attached psmux window
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
$script:procId = $proc.Id
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session did not start"; exit 1 }
Write-Pass "attached psmux session started (pid $($proc.Id))"

# Start the reader child in the pane. It enables VT input mode immediately.
$cmd = "& '$py' '$readerPy' '$readerLog'"
& $PSMUX send-keys -t $SESSION $cmd Enter
Start-Sleep -Seconds 4

# Confirm the reader is up and has enabled VT input mode
if (-not (Test-Path $readerLog)) { Write-Fail "reader child never started (no log)"; Cleanup; exit 1 }
$startLine = (Get-Content $readerLog -Raw)
if ($startLine -match "READER_START.*set_ok=True") { Write-Pass "reader enabled VT input mode (like nvim/Claude Code)" }
else { Write-Fail "reader did not enable VT input mode: $startLine" }

# Baseline: how many 1b bytes before we inject
$before = (Select-String -Path $readerLog -Pattern "\b1b\b" -AllMatches).Matches.Count

# === Inject a BARE <Esc> keypress into psmux (the real TUI keypress path) ===
Write-Host "`n[Inject] bare <Esc> keypress via WriteConsoleInput" -ForegroundColor Yellow
& $injectorExe $proc.Id "{SLEEP:300}{ESC}"
Start-Sleep -Seconds 2

$injLog = Get-Content "$env:TEMP\psmux_inject.log" -Raw
if ($injLog -match "vk=0x1B ok=True") { Write-Host "  injector delivered VK_ESCAPE to psmux OK" -ForegroundColor DarkGray }
else { Write-Host "  WARN injector log: $injLog" -ForegroundColor DarkYellow }

# === Verify: did the child receive 0x1b? ===
$after = (Select-String -Path $readerLog -Pattern "\b1b\b" -AllMatches).Matches.Count
Write-Host "`n[Verify] child stdin bytes after Esc:" -ForegroundColor Yellow
Get-Content $readerLog | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

if ($after -gt $before) {
    Write-Pass "child RECEIVED bare <Esc> (0x1b) -> Esc delivered correctly"
} else {
    Write-Fail "child did NOT receive <Esc> (0x1b) -> BUG #380 REPRODUCED (Esc swallowed)"
}

# Second injection to rule out a one-off: press Esc again
$before2 = $after
& $injectorExe $proc.Id "{SLEEP:200}{ESC}"
Start-Sleep -Seconds 2
$after2 = (Select-String -Path $readerLog -Pattern "\b1b\b" -AllMatches).Matches.Count
if ($after2 -gt $before2) { Write-Pass "second <Esc> also delivered" }
else { Write-Fail "second <Esc> also swallowed" }

Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass" -ForegroundColor Green
Write-Host "  Failed: $script:Fail" -ForegroundColor $(if($script:Fail){"Red"}else{"Green"})
exit $script:Fail
