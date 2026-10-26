# Issue #470: display-popup does not work when invoked from display-menu
#
# ROOT CAUSE: execute_command_string_single() tokenized the popup command with
# split_whitespace(), which leaves shell quotes intact. A menu item command like
# `display-popup -E 'lazygit'` therefore ran the literal `'lazygit'` (quotes and
# all), which is not an executable; the popup shell exited instantly and
# close-on-exit tore the popup down before the user saw it. Fixed by re-tokenizing
# with the quote-aware parse_command_line().
#
# PROOF via dump-state:
#   menu_active  -> menu overlay open
#   popup_active -> popup overlay open (must STAY open after selecting the item)

param([string]$PsmuxExe = (Get-Command psmux -EA Stop).Source)
$ErrorActionPreference = "Continue"
$psmuxDir = "$env:USERPROFILE\.psmux"
$S = "test470"
$injector = "$env:TEMP\psmux_injector.exe"
$script:Pass = 0; $script:Fail = 0

function Cleanup { & $PsmuxExe kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 500; Remove-Item "$psmuxDir\$S.*" -Force -EA SilentlyContinue }
function Info($m){ Write-Host "  $m" -ForegroundColor DarkGray }
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Dump {
    $port = (Get-Content "$psmuxDir\$S.port" -Raw).Trim(); $key = (Get-Content "$psmuxDir\$S.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $tcp.NoDelay=$true; $tcp.ReceiveTimeout=3000
    $st=$tcp.GetStream(); $w=[System.IO.StreamWriter]::new($st); $r=[System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n"); $w.Flush(); $null=$r.ReadLine(); $w.Write("dump-state`n"); $w.Flush()
    $best=$null; for($j=0;$j -lt 60;$j++){ try{$l=$r.ReadLine()}catch{break}; if($null -eq $l){break}; if($l -ne "NC" -and $l.Length -gt 100){$best=$l;break} }
    $tcp.Close(); return $best
}
# Fire a menu, select item by shortcut key, then verify the popup opens AND STAYS open.
function Test-MenuPopup($label, $itemName, $key, $command, [switch]$expectOpen) {
    Write-Host "`n[$label] menu item -> $command" -ForegroundColor Yellow
    & $PsmuxExe display-menu -t $S -T "Menu" $itemName $key $command 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $d = Dump | ConvertFrom-Json
    if (-not $d.menu_active) { Fail "$label menu never opened"; return }
    Info "menu opened (menu_active=True)"
    & $injector $proc.Id $key 2>&1 | Out-Null
    # Poll for popup opening AND persisting (must survive >2s, proving the child did not instantly die)
    $seenOpen=$false; $stillOpenAt2s=$false
    for ($t=0; $t -lt 12; $t++) {
        Start-Sleep -Milliseconds 500
        $d = Dump | ConvertFrom-Json
        if ($d.popup_active) { $seenOpen=$true }
        if ($t -ge 4 -and $d.popup_active) { $stillOpenAt2s=$true }
        Info "t=$([math]::Round($t*0.5,1))s menu=$($d.menu_active) popup_active=$($d.popup_active) has_pty=$($d.popup_has_pty)"
        if ($t -ge 5 -and $stillOpenAt2s) { break }
    }
    if ($expectOpen) {
        if ($stillOpenAt2s) { Pass "$label popup opened and STAYED open" }
        else { Fail "$label popup did not stay open (seenOpen=$seenOpen)" }
    }
    # dismiss the popup so the next sub-test starts clean
    & $injector $proc.Id "{ESC}" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    # if a shell popup is still there, send q
    $d = Dump | ConvertFrom-Json
    if ($d.popup_active) { & $injector $proc.Id "q" 2>&1 | Out-Null; Start-Sleep -Milliseconds 500 }
}

Cleanup
Write-Host "`n=== Issue #470: display-popup from display-menu ===" -ForegroundColor Cyan
$proc = Start-Process -FilePath $PsmuxExe -ArgumentList "new-session","-s",$S -PassThru
Start-Sleep -Seconds 4
& $PsmuxExe has-session -t $S 2>$null
if ($LASTEXITCODE -ne 0){ Fail "session did not start"; exit 1 }

# 1. Reporter's exact shape: quoted multi-word command
#    NOTE: shortcut key must avoid the menu's reserved keys (q/j/k/Enter/Esc);
#    'q' is the menu quit key, so use 'g' (the exact key from the issue report).
Test-MenuPopup "Quoted multi-word" "ping" "g" "display-popup -E 'ping -n 30 127.0.0.1'" -expectOpen

# 2. Quoted single-word command (mirrors `display-popup -E 'lazygit'`), using pwsh which stays alive
Test-MenuPopup "Quoted single-word" "shell" "s" "display-popup -E 'pwsh'" -expectOpen

# 3. Unquoted single-word command (should also still work)
Test-MenuPopup "Unquoted single-word" "shell2" "u" "display-popup -E pwsh" -expectOpen

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:Pass)" -ForegroundColor Green
Write-Host "  Failed: $($script:Fail)" -ForegroundColor $(if($script:Fail){'Red'}else{'Green'})
Cleanup
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
exit $script:Fail
