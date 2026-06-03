# Functional test: Does command-prompt actually open after keybindings?
# Strategy: After injecting prefix+key, type a command and verify if it executed
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "repro303c"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"

# Cleanup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== FUNCTIONAL REPRODUCTION TEST ===" -ForegroundColor Cyan

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[FAIL] Session not created" -ForegroundColor Red; exit 1 }
Write-Host "Session alive, PID=$($proc.Id)"

# === TEST 1: prefix+: (command-prompt) then type a command ===
Write-Host "`n[Test 1] prefix+: then type 'rename-window TESTNAME' + Enter" -ForegroundColor Yellow

$nameBefore = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
Write-Host "  Window name BEFORE: '$nameBefore'"

# Inject prefix + colon to open command prompt
& $injectorExe $proc.Id "^b{SLEEP:500}:"
Start-Sleep -Seconds 1

# Now type the command into the command prompt
& $injectorExe $proc.Id "rename-window TESTNAME303{ENTER}"
Start-Sleep -Seconds 2

$nameAfter = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
Write-Host "  Window name AFTER: '$nameAfter'"

if ($nameAfter -eq "TESTNAME303") {
    Write-Host "  [PASS] prefix+: command-prompt WORKS - window renamed to TESTNAME303" -ForegroundColor Green
} else {
    Write-Host "  [ISSUE] Window name did NOT change. command-prompt may not have opened." -ForegroundColor Red
    Write-Host "  (Could also be that text went to the shell instead of command prompt)"
}

# === TEST 2: prefix+, (rename-window) - default binding ===
Write-Host "`n[Test 2] prefix+, (rename-window direct binding)" -ForegroundColor Yellow

# Reset window name first
& $PSMUX rename-window -t $SESSION "original"
Start-Sleep -Milliseconds 500
$nameBefore2 = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
Write-Host "  Window name BEFORE: '$nameBefore2'"

# Inject prefix + comma
& $injectorExe $proc.Id "^b{SLEEP:500},"
Start-Sleep -Seconds 1

# Try typing a new name (if a rename prompt opened, this should work)
& $injectorExe $proc.Id "RENAMED303{ENTER}"
Start-Sleep -Seconds 2

$nameAfter2 = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
Write-Host "  Window name AFTER: '$nameAfter2'"

if ($nameAfter2 -eq "RENAMED303") {
    Write-Host "  [PASS] prefix+, rename-window WORKS" -ForegroundColor Green
} else {
    Write-Host "  [ISSUE] Window NOT renamed. Prompt did not open or rename failed." -ForegroundColor Red
    Write-Host "  Name remained: '$nameAfter2'"
    # Check capture-pane to see if text went to shell
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap -match "RENAMED303") {
        Write-Host "  [CONFIRMED] Text went to SHELL, not command prompt. PROMPT DID NOT OPEN." -ForegroundColor Red
    }
}

# === TEST 3: prefix+$ (rename-session) - default binding ===
Write-Host "`n[Test 3] prefix+`$ (rename-session)" -ForegroundColor Yellow

$sessNameBefore = (& $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1).Trim()
Write-Host "  Session name BEFORE: '$sessNameBefore'"

# Inject prefix + $
& $injectorExe $proc.Id "^b{SLEEP:500}`$"
Start-Sleep -Seconds 1

# Try typing a new session name
& $injectorExe $proc.Id "NEWSESS303{ENTER}"
Start-Sleep -Seconds 2

# Use the original session name for the query since it may have been renamed
$sessNameAfter = (& $PSMUX display-message -t "NEWSESS303" -p '#{session_name}' 2>&1).Trim()
if ($sessNameAfter -ne "NEWSESS303") {
    # Fallback: try original name
    $sessNameAfter = (& $PSMUX display-message -t $SESSION -p '#{session_name}' 2>&1).Trim()
}
Write-Host "  Session name AFTER: '$sessNameAfter'"

if ($sessNameAfter -eq "NEWSESS303") {
    Write-Host "  [PASS] prefix+`$ rename-session WORKS" -ForegroundColor Green
    $SESSION = "NEWSESS303"  # update for cleanup
} else {
    Write-Host "  [ISSUE] Session NOT renamed. Prompt did not open." -ForegroundColor Red
    # Check if text went to shell
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap -match "NEWSESS303") {
        Write-Host "  [CONFIRMED] Text went to SHELL, not rename prompt." -ForegroundColor Red
    }
}

# === TEST 4: Rebind comma to command-prompt with -I, then test ===
Write-Host "`n[Test 4] Rebind comma to command-prompt, then test" -ForegroundColor Yellow

# Rebind via CLI
& $PSMUX bind-key -t $SESSION "," "command-prompt" "-I" "#W" "rename-window '%%'"
Start-Sleep -Milliseconds 500

# Verify binding
$keys = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
$commaLine = ($keys -split "`n" | Where-Object { $_ -match "bind.*,.*command" })
Write-Host "  Comma binding: $commaLine"

# Reset window name
& $PSMUX rename-window -t $SESSION "beforetest"
Start-Sleep -Milliseconds 500

# Inject prefix+comma
& $injectorExe $proc.Id "^b{SLEEP:500},"
Start-Sleep -Seconds 1

# Type new name
& $injectorExe $proc.Id "CPTEST303{ENTER}"
Start-Sleep -Seconds 2

$nameAfter4 = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
Write-Host "  Window name AFTER rebound prefix+,: '$nameAfter4'"

if ($nameAfter4 -eq "CPTEST303") {
    Write-Host "  [PASS] command-prompt binding via rebind WORKS" -ForegroundColor Green
} else {
    Write-Host "  [ISSUE] command-prompt binding still broken after rebind." -ForegroundColor Red
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1 | Out-String
    if ($cap -match "CPTEST303") {
        Write-Host "  [CONFIRMED] Text went to shell, not command prompt." -ForegroundColor Red
    }
}

# === TEST 5: Does command-prompt work from TCP (manual invocation)? ===
Write-Host "`n[Test 5] command-prompt via direct TCP, then type in TUI" -ForegroundColor Yellow

& $PSMUX rename-window -t $SESSION "tcptest"
Start-Sleep -Milliseconds 500

# Send command-prompt command via TCP
$port = (Get-Content "$psmuxDir\$SESSION.port" -Raw).Trim()
$key = (Get-Content "$psmuxDir\$SESSION.key" -Raw).Trim()
$tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
$tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
$stream = $tcp.GetStream()
$writer = [System.IO.StreamWriter]::new($stream)
$reader = [System.IO.StreamReader]::new($stream)
$writer.Write("AUTH $key`n"); $writer.Flush()
$null = $reader.ReadLine()
$writer.Write("command-prompt -I '#W' 'rename-window `"%%`"'`n"); $writer.Flush()
try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
Write-Host "  TCP command-prompt response: '$resp'"
$tcp.Close()

Start-Sleep -Seconds 1

# Try typing in the TUI
& $injectorExe $proc.Id "TCPNAME303{ENTER}"
Start-Sleep -Seconds 2

$nameAfter5 = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1).Trim()
Write-Host "  Window name AFTER TCP command-prompt + type: '$nameAfter5'"

if ($nameAfter5 -eq "TCPNAME303") {
    Write-Host "  [PASS] command-prompt via TCP then type in TUI WORKS" -ForegroundColor Green
} else {
    Write-Host "  [ISSUE] command-prompt via TCP did not open prompt in TUI." -ForegroundColor Red
}

# Cleanup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== REPRODUCTION COMPLETE ===" -ForegroundColor Cyan
