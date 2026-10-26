# Issue #472: Positive proof the PREFIX binding's ACTION executes when the same key
# has a root binding. prefix C-l -> new-window (detectable); root C-l -> select-pane -R.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue472_pos"
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$pass = 0; $fail = 0
function P($m){Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++}
function F($m){Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++}

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

$conf = "$env:TEMP\psmux_issue472p.conf"
@"
set-option -g prefix C-a
unbind-key C-b
bind-key a send-prefix
bind C-l new-window
bind -n C-l select-pane -R
"@ | Set-Content -Path $conf -Encoding UTF8

Cleanup
$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4
$env:PSMUX_CONFIG_FILE = $null
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "SETUP FAIL"; exit 1 }

# Split so root select-pane -R has an effect, active on LEFT
& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 2
& $PSMUX select-pane -L -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800

$winsBefore = [int](& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()
$paneBefore = (& $PSMUX display-message -t $SESSION -p '#{pane_index}' 2>&1).Trim()

# prefix C-a then C-l => should create a NEW WINDOW, and must NOT move pane
& $injectorExe $proc.Id "^a{SLEEP:400}^l"
Start-Sleep -Seconds 2
$winsAfter = [int](& $PSMUX display-message -t $SESSION -p '#{session_windows}' 2>&1).Trim()

Write-Host "windows $winsBefore -> $winsAfter ; pane before was $paneBefore"
if ($winsAfter -eq $winsBefore + 1) { P "prefix+C-l executed the PREFIX action (new-window)" }
else { F "prefix+C-l did NOT create a window (wins $winsBefore -> $winsAfter)" }

# Sanity: bare C-l (no prefix) still fires root select-pane -R
# Switch to first window's left pane context
& $PSMUX select-window -t "${SESSION}:0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
& $PSMUX select-pane -L -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$pb = (& $PSMUX display-message -t $SESSION -p '#{pane_index}' 2>&1).Trim()
& $injectorExe $proc.Id "^l"
Start-Sleep -Seconds 1
$pa = (& $PSMUX display-message -t $SESSION -p '#{pane_index}' 2>&1).Trim()
Write-Host "bare C-l: pane $pb -> $pa"
if ($pa -ne $pb) { P "bare C-l still fires ROOT binding (select-pane -R) - no regression" }
else { F "bare C-l no longer fires root binding (pane stayed $pa)" }

Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item $conf -Force -EA SilentlyContinue
Write-Host "`nPassed=$pass Failed=$fail"
exit $fail