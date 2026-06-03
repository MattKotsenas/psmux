# Verify keystroke injection works + examine raw dump-state JSON
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "repro303b"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"

function Get-RawDumpState {
    param([string]$Session)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true; $tcp.ReceiveTimeout = 5000
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $null = $reader.ReadLine()
    $writer.Write("dump-state`n"); $writer.Flush()
    try { $resp = $reader.ReadLine() } catch { $resp = $null }
    $tcp.Close()
    return $resp
}

# Cleanup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

Write-Host "`n=== KEYSTROKE INJECTION VALIDATION ===" -ForegroundColor Cyan

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] Session creation failed" -ForegroundColor Red
    exit 1
}

# Check current window count
$winsBefore = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
Write-Host "Windows BEFORE: $winsBefore"

# Test 1: Verify injection works with prefix+c (new-window)
Write-Host "`n[Test] Inject Ctrl+B then 'c' (new-window)" -ForegroundColor Yellow
& $injectorExe $proc.Id "^b{SLEEP:500}c"
Start-Sleep -Seconds 3

$winsAfter = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
Write-Host "Windows AFTER: $winsAfter"

if ([int]$winsAfter -gt [int]$winsBefore) {
    Write-Host "  [PASS] Keystroke injection WORKS (new window created)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Keystroke injection NOT WORKING" -ForegroundColor Red
}

# Test 2: Examine the raw dump-state JSON
Write-Host "`n[Test] Examine raw dump-state JSON structure" -ForegroundColor Yellow
$raw = Get-RawDumpState -Session $SESSION
if ($raw -and $raw.Length -gt 50) {
    # Show first 2000 chars
    $show = $raw.Substring(0, [Math]::Min(2000, $raw.Length))
    Write-Host "Raw JSON (first 2000 chars):"
    Write-Host $show
    
    $json = $raw | ConvertFrom-Json
    Write-Host "`nTop-level fields:"
    $json | Get-Member -MemberType NoteProperty | ForEach-Object { 
        $name = $_.Name
        $val = $json.$name
        if ($val -is [string] -or $val -is [int] -or $val -is [bool] -or $null -eq $val) {
            Write-Host "  $name = $val"
        } else {
            Write-Host "  $name = [$(($val).GetType().Name)]"
        }
    }
} else {
    Write-Host "  No dump-state response or too short" -ForegroundColor Red
}

# Test 3: Now inject prefix+: and check dump-state for mode
Write-Host "`n[Test] Inject prefix+: (command-prompt)" -ForegroundColor Yellow
& $injectorExe $proc.Id "^b{SLEEP:500}:"
Start-Sleep -Seconds 2

$rawAfterColon = Get-RawDumpState -Session $SESSION
if ($rawAfterColon -and $rawAfterColon.Length -gt 50) {
    $jsonColon = $rawAfterColon | ConvertFrom-Json
    Write-Host "Top-level fields AFTER prefix+colon:"
    $jsonColon | Get-Member -MemberType NoteProperty | ForEach-Object {
        $name = $_.Name
        $val = $jsonColon.$name
        if ($val -is [string] -or $val -is [int] -or $val -is [bool] -or $null -eq $val) {
            Write-Host "  $name = $val"
        } else {
            Write-Host "  $name = [$(($val).GetType().Name)]"
        }
    }
    # Specifically check for mode/overlay/command_prompt fields
    Write-Host "`nMode-related fields:"
    Write-Host "  mode: '$($jsonColon.mode)'"
    Write-Host "  overlay: '$($jsonColon.overlay)'"
    Write-Host "  command_prompt: '$($jsonColon.command_prompt)'"
    Write-Host "  input_mode: '$($jsonColon.input_mode)'"
    Write-Host "  popup_active: '$($jsonColon.popup_active)'"
    Write-Host "  confirm_active: '$($jsonColon.confirm_active)'"
}

# Escape
& $injectorExe $proc.Id "{ESC}"
Start-Sleep -Seconds 1

# Cleanup
& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# Also check injector log
Write-Host "`n[Injector Log]:" -ForegroundColor Yellow
$log = Get-Content "$env:TEMP\psmux_inject.log" -Raw -EA SilentlyContinue
if ($log) { Write-Host $log.Substring(0, [Math]::Min(1500, $log.Length)) }
