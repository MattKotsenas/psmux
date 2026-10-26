# Repro for PR #333 / #329 regression: Ctrl+letter double delivery.
# Tests both detached send-keys path AND attached real-keyboard path.
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path "$PSScriptRoot\..\target\release\psmux.exe").Path
$session = "ctrlw_$(Get-Random)"
$pass = 0; $fail = 0
function ok($m){$script:pass++; Write-Host "PASS: $m" -ForegroundColor Green}
function bad($m){$script:fail++; Write-Host "FAIL: $m" -ForegroundColor Red}

try {
  & $exe kill-server 2>$null | Out-Null; Start-Sleep -Milliseconds 300

  # Layer 1: detached send-keys C-w through pwsh + PSReadLine
  & $exe -L $session new-session -d -s $session -x 120 -y 30 'pwsh -NoLogo -NoProfile' | Out-Null
  Start-Sleep -Milliseconds 1500
  # Wait for prompt
  $tries = 0
  do {
    Start-Sleep -Milliseconds 400
    $cap = (& $exe -L $session capture-pane -p -t "${session}:0") -join "`n"
    $tries++
  } while ($cap -notmatch 'PS\s' -and $tries -lt 20)

  # Disable PSReadLine's inline history-prediction ghost text before typing.
  # Root-cause note (2026-07-18 debugging pass): on a dev machine whose
  # persisted $PROFILE-independent ConsoleHost_history.txt already contains
  # an entry starting with "Hello World " + a long run of CJK filler (from
  # unrelated earlier manual CJK testing on this exact repo), PSReadLine's
  # default PredictionSource=History renders that entry as inline ghost
  # text the moment the buffer prefix-matches it. capture-pane faithfully
  # captures that ghost text (it's real VT screen content pwsh drew), which
  # LOOKS like Ctrl+W corrupted/duplicated CJK text but is unrelated to
  # Ctrl+W or word-delete: Ctrl+W only edits the real input buffer, and the
  # ghost suggestion simply re-renders against the shortened buffer since it
  # still prefix-matches. Confirmed by disabling prediction: Ctrl+W then
  # deletes exactly one word every time, with zero CJK ever appearing.
  & $exe -L $session send-keys -t "${session}:0" "Set-PSReadLineOption -PredictionSource None" Enter | Out-Null
  Start-Sleep -Milliseconds 600

  # Type "hello world" then Ctrl+W
  & $exe -L $session send-keys -t "${session}:0" "hello world" | Out-Null
  Start-Sleep -Milliseconds 400
  & $exe -L $session send-keys -t "${session}:0" C-w | Out-Null
  Start-Sleep -Milliseconds 600

  $cap2 = (& $exe -L $session capture-pane -p -t "${session}:0") -join "`n"
  Write-Host "--- Pane after Ctrl+W ---"
  Write-Host $cap2
  Write-Host "--- end ---"

  # Single delivery: PSReadLine BackwardKillWord deletes "world" only, leaves "hello "
  # Double delivery: deletes "world", then deletes "hello", line empty after prompt
  $lastLine = ($cap2 -split "`n" | Where-Object { $_ -match 'PS\s' } | Select-Object -Last 1)
  Write-Host "Last prompt line: '$lastLine'"

  if ($lastLine -match 'hello\s*$') {
    ok "Ctrl+W deleted exactly one word ('world'); 'hello ' remains - single delivery"
  } elseif ($lastLine -match '>\s*$') {
    bad "Ctrl+W deleted BOTH words; line empty - DOUBLE DELIVERY"
  } else {
    bad "unexpected pane state: $lastLine"
  }
}
finally {
  & $exe -L $session kill-server 2>$null | Out-Null
}
Write-Host "`n$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
