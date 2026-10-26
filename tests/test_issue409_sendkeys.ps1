# Issue #409 companion / regression guard for the send-keys route.
#
# IMPORTANT: `send-keys` modified-Enter is a SEPARATE code path from the
# interactive keypress fix.  send-keys is dispatched server-side
# (server/mod.rs -> parse_modified_special_key).  This test locks in the bytes
# that route delivers so an interactive change cannot silently alter scripted
# send-keys behaviour.
#
# History: until #611 the route emitted xterm CSI 13;N~ for every modified
# Enter.  Measured in #611, a ReadConsoleInput reader gets ZERO records for
# that form and a VT-input (node raw mode) reader gets the raw CSI bytes,
# which no node TUI maps to a modified Enter.  Since #611 the route mirrors
# encode_key_event, i.e. what a real keystroke produces and what tmux writes
# for M-Enter (`` prefix then CR):
#   send-keys Enter    -> 0x0D (CR)            plain Enter
#   send-keys C-Enter  -> 0x0A (LF)            same as the interactive #409 fix
#   send-keys S-Enter  -> 1b 0d                ESC CR, what libuv reports as meta+return
#   send-keys M-Enter  -> 1b 0d                ESC CR, tmux M-Enter parity
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue409sk"
$psmuxDir = "$env:USERPROFILE\.psmux"
$recv = "$env:TEMP\psmux_409sk_recv.log"
$recvJs = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "ctrl_enter_recv.js"
$pass = 0; $fail = 0
function P($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION.*",$recv -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4
& $PSMUX send-keys -t $SESSION "node `"$recvJs`" `"$recv`"" Enter 2>&1 | Out-Null
$ready=$false; for($i=0;$i -lt 40;$i++){ Start-Sleep -Milliseconds 250; if((Test-Path $recv) -and ((Get-Content $recv -Raw) -match "READY")){$ready=$true;break} }
if(-not $ready){ F "receiver not ready"; & $PSMUX kill-session -t $SESSION 2>&1|Out-Null; exit 1 }

function SendKeyCheck($key,$expectHex,$label){
    $before = @(Get-Content $recv | Where-Object { $_ -like "BYTES:*" }).Count
    & $PSMUX send-keys -t $SESSION $key 2>&1 | Out-Null
    Start-Sleep -Milliseconds 700
    $lines = @(Get-Content $recv | Where-Object { $_ -like "BYTES:*" })
    $new = if($lines.Count -gt $before){ ($lines[$before..($lines.Count-1)] -join " ") } else { "(none)" }
    if($new -match $expectHex){ P "send-keys $label -> $new (expected $expectHex)" }
    else { F "send-keys $label -> $new (expected $expectHex)" }
}

Write-Host "`n=== #409 send-keys path (server-side, separate from interactive fix) ===" -ForegroundColor Cyan
SendKeyCheck "Enter"   "^BYTES: 0d$"                    "Enter"
SendKeyCheck "C-Enter" "^BYTES: 0a$"                    "C-Enter (LF, #409)"
SendKeyCheck "S-Enter" "^BYTES: 1b 0d$"                 "S-Enter (ESC CR, #611)"
SendKeyCheck "M-Enter" "^BYTES: 1b 0d$"                 "M-Enter (ESC CR, tmux parity)"

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
Write-Host "`nPassed: $pass  Failed: $fail" -ForegroundColor $(if($fail){"Red"}else{"Green"})
Write-Host "Full log:" -ForegroundColor DarkGray
Get-Content $recv | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
exit $fail
