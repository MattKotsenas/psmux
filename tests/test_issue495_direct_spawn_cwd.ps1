# Issue #495 follow-up: #{pane_current_path} must track `cd` in PowerShell
# panes spawned as EXPLICIT commands (new-window/split-window with a full
# pwsh.exe or powershell.exe path), not only in default-shell panes.
# Reported in issue #495 comment: user with both PS 5.1 and pwsh 7 installed
# saw stale paths in both shell types.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

$PS51 = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$PWSH = (Get-Command pwsh -EA SilentlyContinue).Source
$CMDEXE = "C:\Windows\System32\cmd.exe"

function Cleanup {
    foreach ($s in @("t495ds_a", "t495ds_b", "t495ds_tui")) {
        & $PSMUX kill-session -t $s 2>&1 | Out-Null
        Remove-Item "$psmuxDir\$s.*" -Force -EA SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
}

# Sends a cd to the active pane and returns pane_current_path after it.
function Test-CdTracking {
    param([string]$Session, [string]$Dest)
    & $PSMUX send-keys -t $Session "cd $Dest" Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    return (& $PSMUX display-message -t $Session -p '#{pane_current_path}' 2>&1 | Out-String).Trim()
}

Cleanup
Write-Host "`n=== Issue #495 follow-up: direct-spawn PowerShell cwd tracking ===" -ForegroundColor Cyan

# === SETUP: session whose default shell is PS 5.1 (the reporter's setup) ===
$conf = "$env:TEMP\psmux_t495ds.conf"
"set -g default-shell `"$PS51`"" | Set-Content $conf -Encoding UTF8
$env:PSMUX_CONFIG_FILE = $conf
$env:PSMUX_NO_WARM = "1"
& $PSMUX new-session -d -s t495ds_a
Start-Sleep -Seconds 5
$env:PSMUX_CONFIG_FILE = $null
$env:PSMUX_NO_WARM = $null

& $PSMUX has-session -t t495ds_a 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Session creation failed"; exit 1 }

# === TEST 1: default-shell PS 5.1 pane tracks cd (aef2d1d regression guard) ===
Write-Host "`n[Test 1] Default-shell PS 5.1 pane tracks cd" -ForegroundColor Yellow
$p = Test-CdTracking "t495ds_a" "C:\Windows\System32"
if ($p -eq "C:\Windows\System32") { Write-Pass "PS 5.1 default-shell pane: $p" }
else { Write-Fail "PS 5.1 default-shell pane stale: $p" }

# === TEST 2: explicit pwsh window inside PS 5.1 session tracks cd ===
if ($PWSH) {
    Write-Host "`n[Test 2] Explicit pwsh command pane tracks cd (the reported gap)" -ForegroundColor Yellow
    & $PSMUX new-window -t t495ds_a $PWSH 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $shell = (& $PSMUX display-message -t t495ds_a -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
    if ($shell -eq "pwsh") { Write-Pass "Window is running pwsh" }
    else { Write-Fail "Expected pwsh pane, got: $shell" }
    $p = Test-CdTracking "t495ds_a" "C:\Windows\Temp"
    if ($p -eq "C:\Windows\Temp") { Write-Pass "Explicit pwsh pane tracks cd: $p" }
    else { Write-Fail "Explicit pwsh pane stale: $p" }
} else {
    Write-Host "`n[Test 2] SKIP: pwsh not installed" -ForegroundColor DarkYellow
}

# === TEST 3: explicit powershell.exe window tracks cd ===
Write-Host "`n[Test 3] Explicit powershell.exe command pane tracks cd" -ForegroundColor Yellow
& $PSMUX new-window -t t495ds_a $PS51 2>&1 | Out-Null
Start-Sleep -Seconds 4
$p = Test-CdTracking "t495ds_a" "C:\Windows\Temp"
if ($p -eq "C:\Windows\Temp") { Write-Pass "Explicit powershell.exe pane tracks cd: $p" }
else { Write-Fail "Explicit powershell.exe pane stale: $p" }

# === TEST 4: explicit cmd.exe pane still tracks cd (native, untouched) ===
Write-Host "`n[Test 4] Explicit cmd.exe pane unaffected" -ForegroundColor Yellow
& $PSMUX new-window -t t495ds_a $CMDEXE 2>&1 | Out-Null
Start-Sleep -Seconds 3
$shell = (& $PSMUX display-message -t t495ds_a -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
if ($shell -eq "cmd") { Write-Pass "cmd.exe pane spawned without PowerShell flags" }
else { Write-Fail "Expected cmd pane, got: $shell" }
$p = Test-CdTracking "t495ds_a" "C:\Windows\Temp"
if ($p -eq "C:\Windows\Temp") { Write-Pass "cmd.exe pane tracks cd: $p" }
else { Write-Fail "cmd.exe pane stale: $p" }

# === TEST 5: split-window with explicit pwsh path tracks cd ===
if ($PWSH) {
    Write-Host "`n[Test 5] split-window explicit pwsh pane tracks cd" -ForegroundColor Yellow
    & $PSMUX split-window -t t495ds_a $PWSH 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $p = Test-CdTracking "t495ds_a" "C:\Users"
    if ($p -eq "C:\Users") { Write-Pass "split pwsh pane tracks cd: $p" }
    else { Write-Fail "split pwsh pane stale: $p" }
}

# === TEST 6: pwsh pane with -NoProfile still tracks cd ===
if ($PWSH) {
    Write-Host "`n[Test 6] Explicit pwsh -NoProfile pane tracks cd" -ForegroundColor Yellow
    & $PSMUX new-window -t t495ds_a "$PWSH -NoProfile" 2>&1 | Out-Null
    Start-Sleep -Seconds 4
    $p = Test-CdTracking "t495ds_a" "C:\Windows\System32"
    if ($p -eq "C:\Windows\System32") { Write-Pass "pwsh -NoProfile pane tracks cd: $p" }
    else { Write-Fail "pwsh -NoProfile pane stale: $p" }
}

# === TEST 7: non-interactive pwsh command pane is NOT wrapped ===
if ($PWSH) {
    Write-Host "`n[Test 7] pwsh -Command pane runs the command verbatim" -ForegroundColor Yellow
    & $PSMUX new-window -t t495ds_a "$PWSH -NoProfile -Command Start-Sleep 30" 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    $cap = (& $PSMUX capture-pane -t t495ds_a -p 2>&1 | Out-String)
    # The init block would echo nothing, but a broken duplicate -Command would
    # print a parameter binding error. Absence of an error line is the check.
    if ($cap -notmatch "Cannot process|ParameterBindingException|is not recognized") {
        Write-Pass "No parameter collision on -Command pane"
    } else { Write-Fail "Parameter error in -Command pane: $($cap.Trim())" }
}

# === TEST 8: TCP server path (new-window via raw socket) ===
Write-Host "`n[Test 8] TCP server path: new-window with explicit PS 5.1 path" -ForegroundColor Yellow
$port = (Get-Content "$psmuxDir\t495ds_a.port" -Raw -EA SilentlyContinue).Trim()
$key = (Get-Content "$psmuxDir\t495ds_a.key" -Raw -EA SilentlyContinue).Trim()
if ($port -and $key) {
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("new-window $PS51`n"); $writer.Flush()
    $stream.ReadTimeout = 10000
    try { $null = $reader.ReadLine() } catch {}
    $tcp.Close()
    Start-Sleep -Seconds 4
    $p = Test-CdTracking "t495ds_a" "C:\Windows\Temp"
    if ($p -eq "C:\Windows\Temp") { Write-Pass "TCP-spawned powershell.exe pane tracks cd: $p" }
    else { Write-Fail "TCP-spawned powershell.exe pane stale: $p" }
} else {
    Write-Fail "Could not read port/key for TCP test"
}

& $PSMUX kill-session -t t495ds_a 2>&1 | Out-Null

# === Win32 TUI VISUAL VERIFICATION ===
Write-Host "`n=== Win32 TUI visual verification ===" -ForegroundColor Cyan
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s","t495ds_tui" -PassThru
Start-Sleep -Seconds 4
& $PSMUX has-session -t t495ds_tui 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "TUI: attached session alive"
    if ($PWSH) {
        & $PSMUX split-window -t t495ds_tui $PWSH 2>&1 | Out-Null
        Start-Sleep -Seconds 4
        $panes = (& $PSMUX display-message -t t495ds_tui -p '#{window_panes}' 2>&1 | Out-String).Trim()
        if ($panes -eq "2") { Write-Pass "TUI: split created pwsh pane" }
        else { Write-Fail "TUI: expected 2 panes, got $panes" }
        $p = Test-CdTracking "t495ds_tui" "C:\Windows\Temp"
        if ($p -eq "C:\Windows\Temp") { Write-Pass "TUI: attached pwsh pane tracks cd: $p" }
        else { Write-Fail "TUI: attached pwsh pane stale: $p" }
    }
} else {
    Write-Fail "TUI: attached session did not come up"
}
& $PSMUX kill-session -t t495ds_tui 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Cleanup
Remove-Item $conf -Force -EA SilentlyContinue

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
