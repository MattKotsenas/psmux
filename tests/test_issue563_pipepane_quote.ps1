# Issue #563: pipe-pane's CLI arm never quoted the piped command, so the server's
# join(" ") could not restore stripped quoting; a single quoted argument with a
# space arrived at the child as several arguments. The fix routes the token
# through quote_arg_if_needed so the join becomes an identity.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$script:Pass = 0; $script:Fail = 0
function Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

New-Item -ItemType Directory -Force -Path C:\Temp\t563pf | Out-Null
@'
"count=" + $args.Count | Set-Content C:\Temp\t563pf\args.txt
foreach ($a in $args) { Add-Content C:\Temp\t563pf\args.txt ("[" + $a + "]") }
[Console]::In.ReadToEnd() | Out-Null
'@ | Set-Content C:\Temp\t563pf\show.ps1

function Probe($sink) {
  Remove-Item C:\Temp\t563pf\args.txt -ErrorAction SilentlyContinue
  & $PSMUX kill-session -t t563pf 2>&1 | Out-Null
  Start-Sleep -Milliseconds 400
  & $PSMUX new-session -d -s t563pf | Out-Null
  Start-Sleep 4
  & $PSMUX pipe-pane -t t563pf $sink | Out-Null
  Start-Sleep 3
  & $PSMUX kill-session -t t563pf | Out-Null
  Start-Sleep 2
  (Get-Content C:\Temp\t563pf\args.txt -ErrorAction SilentlyContinue | Where-Object { $_ -match '^count=' })
}

Write-Host "=== Issue #563: pipe-pane quoting ===" -ForegroundColor Cyan
$ctrl = Probe '& C:\Temp\t563pf\show.ps1 abc'
$bug  = Probe '& C:\Temp\t563pf\show.ps1 "a b c"'
Write-Host "  control=$ctrl  quoted=$bug"
if ($ctrl -eq 'count=1') { Pass "control (no-space arg) delivered as 1 arg" }
else { Fail "control invalid: $ctrl" }
if ($bug -eq 'count=1') { Pass "quoted 'a b c' delivered intact as 1 arg" }
else { Fail "quoted arg split: $bug (expected count=1)" }

Write-Host "`nPassed=$script:Pass Failed=$script:Fail"
exit $script:Fail
