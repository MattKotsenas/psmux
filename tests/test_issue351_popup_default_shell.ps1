#!/usr/bin/env pwsh
# Regression test for issue #351: display-popup with no command should open
# an interactive shell-backed popup, not a static close-only message.

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\tcp_reply_common.ps1"
$results = @()

function Add-Result($name, $pass, $detail = "") {
    $script:results += [PSCustomObject]@{
        Test = $name
        Result = if ($pass) { "PASS" } else { "FAIL" }
        Detail = $detail
    }
}

$PSMUX = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe" -ErrorAction SilentlyContinue).Path
if (-not $PSMUX) { $PSMUX = (Resolve-Path "$PSScriptRoot\..\target\debug\psmux.exe" -ErrorAction SilentlyContinue).Path }
if (-not $PSMUX) { $PSMUX = (Get-Command psmux -ErrorAction SilentlyContinue).Source }
if (-not $PSMUX) { Write-Error "psmux binary not found"; exit 1 }

$SESSION = "test351popup_$PID"
$homeDir = $env:USERPROFILE

function Get-Port {
    (Get-Content "$homeDir\.psmux\$SESSION.port").Trim()
}

function Get-Key {
    if (Test-Path "$homeDir\.psmux\$SESSION.key") {
        (Get-Content "$homeDir\.psmux\$SESSION.key").Trim()
    } else {
        ""
    }
}

function Send-ControlLine {
    param(
        [string]$Line,
        [int]$DelayMs = 500
    )

    $tcp = [System.Net.Sockets.TcpClient]::new()
    $tcp.Connect("127.0.0.1", [int](Get-Port))
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $writer.AutoFlush = $true
    $writer.WriteLine("AUTH $(Get-Key)")
    $writer.WriteLine($Line)
    Start-Sleep -Milliseconds $DelayMs
    $tcp.Close()
}

function Get-DumpState {
    param([int]$DelayMs = 1200)

    $tcp = [System.Net.Sockets.TcpClient]::new()
    $tcp.Connect("127.0.0.1", [int](Get-Port))
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $writer.AutoFlush = $true
    $writer.WriteLine("AUTH $(Get-Key)")
    $writer.WriteLine("dump-state")
    # The reply ends when the server closes the connection (tcp_reply_common.ps1);
    # DelayMs is now only the upper bound on the wait.
    $resp = Read-TcpReplyToEof -Stream $stream -TimeoutMs ([Math]::Max($DelayMs, 5000))
    $tcp.Close()
    return $resp
}

try {
    & $PSMUX kill-session -t $SESSION 2>$null | Out-Null
    Start-Sleep -Milliseconds 300

    & $PSMUX new-session -d -s $SESSION -x 120 -y 30 | Out-Null
    Start-Sleep -Seconds 2

    & $PSMUX display-popup -t $SESSION -E -w "80%" -h "80%" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800

    $json = Get-DumpState
    Add-Result "popup is active" ($json -match '"popup_active"\s*:\s*true')
    Add-Result "popup has PTY" ($json -match '"popup_has_pty"\s*:\s*true')
    Add-Result "popup command is empty/default shell" ($json -match '"popup_command"\s*:\s*""')
    Add-Result "not static close-text popup" (-not ($json -match "Press 'q' or Escape to close"))

    $token = "ISSUE351_POPUP_INPUT"
    $inputBytes = [System.Text.Encoding]::UTF8.GetBytes("echo $token`r")
    $encoded = [Convert]::ToBase64String($inputBytes)
    Send-ControlLine "popup-input $encoded" 500

    $inputSeen = $false
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        $json = Get-DumpState 300
        if ($json -match $token) {
            $inputSeen = $true
            break
        }
    }
    Add-Result "popup input reaches shell" $inputSeen
} finally {
    Send-ControlLine "overlay-close" 200 2>$null
    & $PSMUX kill-session -t $SESSION 2>$null | Out-Null
    Remove-Item "$homeDir\.psmux\$SESSION.port" -Force -ErrorAction SilentlyContinue
    Remove-Item "$homeDir\.psmux\$SESSION.key" -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== Issue #351: Default popup shell test results ==="
$results | Format-Table -AutoSize
$failed = ($results | Where-Object { $_.Result -eq "FAIL" }).Count
if ($failed -gt 0) { exit 1 }
exit 0
