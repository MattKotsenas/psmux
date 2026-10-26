# Issue #472: Confirm prefix mode IS entered, isolating the bug to same-key root/prefix resolution
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue472_confirm"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# Config: prefix C-a. Two prefix bindings:
#   n  -> new-window        (NO root conflict -> proves prefix mode works)
#   C-l -> send-keys clear   (HAS root conflict C-l select-pane -R -> the bug)
$conf = "$env:TEMP\psmux_issue472c.conf"
@"
set-option -g prefix C-a
unbind-key C-b
bind-key a send-prefix
bind n new-window
bind C-l send-keys clear Enter
bind -n C-l select-pane -R
"@ | Set-Content -Path $conf -Encoding UTF8

Cleanup
$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4
$env:PSMUX_CONFIG_FILE = $null
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "SETUP FAIL"; exit 1 }

# --- CONTROL: prefix + n (no root conflict) should create a new window ---
$winsBefore = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
& $injectorExe $proc.Id "^a{SLEEP:400}n"
Start-Sleep -Seconds 2
$winsAfter = (& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
Write-Host "[CONTROL prefix+n] windows $winsBefore -> $winsAfter"
if ([int]$winsAfter -gt [int]$winsBefore) {
    Write-Host "  PROVEN: prefix mode IS entered (non-conflicting prefix binding fires)" -ForegroundColor Green
} else {
    Write-Host "  Prefix mode NOT entered - test invalid" -ForegroundColor Red
}

# --- THE BUG: prefix + C-l (root conflict) ---
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX select-pane -L -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$paneReset = (& $PSMUX display-message -t $SESSION -p '#{pane_index}' 2>&1).Trim()

& $injectorExe $proc.Id "^a{SLEEP:400}^l"
Start-Sleep -Seconds 1
$paneAfter = (& $PSMUX display-message -t $SESSION -p '#{pane_index}' 2>&1).Trim()
Write-Host "[BUG prefix+C-l] active pane $paneReset -> $paneAfter"
if ($paneAfter -ne $paneReset) {
    Write-Host "  BUG CONFIRMED: root binding fired despite prefix mode working for other keys" -ForegroundColor Red
} else {
    Write-Host "  Prefix binding fired correctly" -ForegroundColor Green
}

Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item $conf -Force -EA SilentlyContinue