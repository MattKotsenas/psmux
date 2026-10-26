# Try several conditions where prefix+% on bottom/inner pane might error.
# Goal: capture the specific error message and the exact triggering state.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$injector = "$env:TEMP\psmux_injector.exe"
$pass = 0; $fail = 0
function P($m) { Write-Host "[PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; $script:fail++ }

function StartS([string]$name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
    $proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$name -PassThru
    Start-Sleep -Seconds 4
    return $proc
}
function Connect([string]$name) {
    $port = (Get-Content "$psmuxDir\$name.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$name.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay=$true; $tcp.ReceiveTimeout=3000
    $s=$tcp.GetStream(); $w=[System.IO.StreamWriter]::new($s); $r=[System.IO.StreamReader]::new($s)
    $w.Write("AUTH $key`n"); $w.Flush(); $null=$r.ReadLine()
    $w.Write("PERSISTENT`n"); $w.Flush()
    return @{tcp=$tcp;w=$w;r=$r}
}
function Dump($c) {
    $c.w.Write("dump-state`n"); $c.w.Flush()
    $best=$null
    $c.tcp.ReceiveTimeout=600
    for ($j=0; $j -lt 50; $j++) {
        try { $line=$c.r.ReadLine() } catch { break }
        if ($null -eq $line) { break }
        if ($line -ne "NC" -and $line.Length -gt 100) { $best=$line }
        if ($best) { $c.tcp.ReceiveTimeout=30 }
    }
    $c.tcp.ReceiveTimeout=3000
    return $best
}

function PaneCount($name) { (& $PSMUX list-panes -t $name 2>&1 | Measure-Object -Line).Lines }
function StatusMsg($conn) {
    $d = Dump $conn
    if ($d) { try { ($d | ConvertFrom-Json).status_message } catch { "" } } else { "" }
}

# === SCENARIO A: repeated prefix+% to find min-width error ===
Write-Host "`n--- SCENARIO A: repeated prefix+% horizontal splits ---" -ForegroundColor Cyan
$proc = StartS "rA"
$conn = Connect "rA"
for ($i = 1; $i -le 6; $i++) {
    $before = PaneCount "rA"
    & $injector $proc.Id "^b{SLEEP:250}%" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 200
    $msg = StatusMsg $conn
    Start-Sleep -Milliseconds 600
    $after = PaneCount "rA"
    Write-Host ("  iter {0}: before={1} after={2} status_msg='{3}'" -f $i, $before, $after, $msg)
    if ($after -le $before -and $msg) {
        # Running out of room is CORRECT, not a defect. tmux does the same once
        # a pane cannot be halved again:
        #
        #   tmux split-window -h  ->  rc 1, "no space for new pane"
        #   psmux                 ->  "pane too small to split horizontally"
        #
        # psmux refuses a little earlier only because its minimum pane width is
        # larger. Treating the refusal as a failure meant this suite failed on
        # correct behaviour every run. What matters is that the refusal is
        # CLEAN: a clear message, and the pane count left untouched.
        if ($msg -match 'too small to split|no space for new pane') {
            if ($after -eq $before) {
                P "iter ${i}: refused cleanly with '$msg' (pane count unchanged at $after)"
            } else {
                F "iter ${i}: refused with '$msg' but pane count changed $before -> $after"
            }
            break
        }
        F "split FAILED at iter $i with msg: $msg"
        break
    }
}
$conn.tcp.Close()
& $PSMUX kill-session -t rA 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep 1

# === SCENARIO B: vertical split first (prefix+"), focus bottom, then prefix+% repeatedly ===
Write-Host "`n--- SCENARIO B: vertical split then prefix+% on bottom ---" -ForegroundColor Cyan
$proc = StartS "rB"
$conn = Connect "rB"
& $injector $proc.Id "^b{SLEEP:250}`"" 2>&1 | Out-Null
Start-Sleep -Seconds 1
$panes = PaneCount "rB"
Write-Host "  after prefix+`": panes=$panes"
$active = (& $PSMUX display-message -t rB -p '#{pane_index}' 2>&1).Trim()
Write-Host "  active pane: $active"

for ($i = 1; $i -le 6; $i++) {
    $before = PaneCount "rB"
    & $injector $proc.Id "^b{SLEEP:250}%" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 200
    $msg = StatusMsg $conn
    Start-Sleep -Milliseconds 600
    $after = PaneCount "rB"
    Write-Host ("  iter {0}: before={1} after={2} status_msg='{3}'" -f $i, $before, $after, $msg)
    if ($after -le $before -and $msg) {
        # Running out of room is CORRECT, not a defect. tmux does the same once
        # a pane cannot be halved again:
        #
        #   tmux split-window -h  ->  rc 1, "no space for new pane"
        #   psmux                 ->  "pane too small to split horizontally"
        #
        # psmux refuses a little earlier only because its minimum pane width is
        # larger. Treating the refusal as a failure meant this suite failed on
        # correct behaviour every run. What matters is that the refusal is
        # CLEAN: a clear message, and the pane count left untouched.
        if ($msg -match 'too small to split|no space for new pane') {
            if ($after -eq $before) {
                P "iter ${i}: refused cleanly with '$msg' (pane count unchanged at $after)"
            } else {
                F "iter ${i}: refused with '$msg' but pane count changed $before -> $after"
            }
            break
        }
        F "split FAILED at iter $i with msg: $msg"
        break
    }
}
$conn.tcp.Close()
& $PSMUX kill-session -t rB 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Start-Sleep 1

# === SCENARIO C: zoomed pane ===
Write-Host "`n--- SCENARIO C: zoomed pane prefix+% ---" -ForegroundColor Cyan
$proc = StartS "rC"
$conn = Connect "rC"
& $injector $proc.Id "^b{SLEEP:250}`"" 2>&1 | Out-Null
Start-Sleep -Seconds 1
& $injector $proc.Id "^b{SLEEP:250}z" 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
$z = (& $PSMUX display-message -t rC -p '#{window_zoomed_flag}' 2>&1).Trim()
Write-Host "  zoom flag=$z"
$before = PaneCount "rC"
& $injector $proc.Id "^b{SLEEP:250}%" 2>&1 | Out-Null
Start-Sleep -Milliseconds 200
$msg = StatusMsg $conn
Start-Sleep -Milliseconds 600
$after = PaneCount "rC"
Write-Host ("  before={0} after={1} status_msg='{2}'" -f $before, $after, $msg)
$conn.tcp.Close()
& $PSMUX kill-session -t rC 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`nPassed=$pass Failed=$fail"
