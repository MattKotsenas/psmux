# Issue #472: Prefix table key binding ignored when same key exists in root table
# REPRODUCTION test - proves whether prefix+C-l fires the PREFIX binding or the ROOT binding
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue472_repro"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# Exact config from the issue
$conf = "$env:TEMP\psmux_issue472.conf"
@"
set-option -g prefix C-a
unbind-key C-b
bind-key a send-prefix
bind C-l send-keys clear Enter
bind -n C-l select-pane -R
"@ | Set-Content -Path $conf -Encoding UTF8

Cleanup
$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4
$env:PSMUX_CONFIG_FILE = $null

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "SETUP FAIL: session not created"; exit 1 }

# Confirm list-keys shows both bindings (issue note: tmux list-keys shows both)
$keys = & $PSMUX list-keys -t $SESSION 2>&1 | Out-String
Write-Host "--- list-keys C-l lines ---"
($keys -split "`n") | Where-Object { $_ -match "C-l" } | ForEach-Object { Write-Host "  $_" }

# Create a horizontal split so there is a left and right pane
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2
# Move active to LEFT pane so select-pane -R has room to move right
& $PSMUX select-pane -L -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$paneStart = (& $PSMUX display-message -t $SESSION -p '#{pane_index}' 2>&1).Trim()
$panesCount = (& $PSMUX display-message -t $SESSION -p '#{window_panes}' 2>&1).Trim()
Write-Host "`nPanes=$panesCount  ActivePaneBefore=$paneStart"

# ---- CONTROL: press C-l with NO prefix -> should fire ROOT binding (select-pane -R) ----
& $injectorExe $proc.Id "^l"
Start-Sleep -Seconds 1
$paneAfterRoot = (& $PSMUX display-message -t $SESSION -p '#{pane_index}' 2>&1).Trim()
Write-Host "[CONTROL] After bare C-l: ActivePane=$paneAfterRoot (expect moved right = root binding works)"

# Move back to left pane
& $PSMUX select-pane -L -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
$paneReset = (& $PSMUX display-message -t $SESSION -p '#{pane_index}' 2>&1).Trim()
Write-Host "Reset active pane to: $paneReset"

# ---- THE TEST: press PREFIX (C-a) then C-l -> should fire PREFIX binding (clear), NOT move pane ----
& $injectorExe $proc.Id "^a{SLEEP:400}^l"
Start-Sleep -Seconds 1
$paneAfterPrefix = (& $PSMUX display-message -t $SESSION -p '#{pane_index}' 2>&1).Trim()
Write-Host "[TEST] After prefix C-a then C-l: ActivePane=$paneAfterPrefix (reset was $paneReset)"

Write-Host "`n=== VERDICT ==="
if ($paneAfterPrefix -ne $paneReset) {
    Write-Host "BUG REPRODUCED: prefix+C-l MOVED the active pane ($paneReset -> $paneAfterPrefix)." -ForegroundColor Red
    Write-Host "  => The ROOT binding (select-pane -R) fired instead of the PREFIX binding." -ForegroundColor Red
} else {
    Write-Host "NOT REPRODUCED: prefix+C-l did NOT move the pane (stayed $paneAfterPrefix)." -ForegroundColor Green
    Write-Host "  => The PREFIX binding fired correctly." -ForegroundColor Green
}

Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item $conf -Force -EA SilentlyContinue