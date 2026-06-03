# PR #347 / zoom PTY full-area sizing
# Verifies the active pane's PTY is resized to the FULL window area when
# zoomed (not 2 cols/rows short due to gap+min-size steal).
$ErrorActionPreference = 'Stop'
$exe = Join-Path $PSScriptRoot '..\target\release\psmux.exe'
$exe = (Resolve-Path $exe).Path

$session = "pr347_$(Get-Random)"
$pass = 0; $fail = 0
function ok($msg){ $script:pass++; Write-Host "PASS: $msg" -ForegroundColor Green }
function bad($msg){ $script:fail++; Write-Host "FAIL: $msg" -ForegroundColor Red }

try {
  & $exe kill-server 2>$null | Out-Null
  Start-Sleep -Milliseconds 300
  & $exe -L $session new-session -d -s $session -x 120 -y 40 | Out-Null
  & $exe -L $session split-window -h -t "${session}:0" | Out-Null
  & $exe -L $session split-window -v -t "${session}:0" | Out-Null

  # Capture pane sizes BEFORE zoom
  $before = & $exe -L $session list-panes -t "${session}:0" -F "#{pane_index} #{pane_width}x#{pane_height}"
  Write-Host "BEFORE zoom:`n$($before -join [Environment]::NewLine)"

  # Zoom active pane
  & $exe -L $session resize-pane -Z -t "${session}:0" | Out-Null
  Start-Sleep -Milliseconds 250

  # Force a resize cycle by applying refresh-client (which triggers resize_all_panes)
  & $exe -L $session refresh-client -t $session 2>$null | Out-Null
  Start-Sleep -Milliseconds 200

  $after = & $exe -L $session list-panes -t "${session}:0" -F "#{pane_index} #{pane_active} #{pane_width}x#{pane_height}"
  Write-Host "AFTER zoom:`n$($after -join [Environment]::NewLine)"

  # Find active pane line
  $activeLine = $after | Where-Object { $_ -match '^\d+ 1 ' } | Select-Object -First 1
  if (-not $activeLine) { bad "no active pane found"; throw "halt" }
  if ($activeLine -match '(\d+)x(\d+)$') {
    $w = [int]$Matches[1]; $h = [int]$Matches[2]
    Write-Host "Active zoomed pane: ${w}x${h}"
    # window is 120x40; status bar takes 1 row, so content area is 120x39
    if ($w -ge 119) { ok "active width ($w) >= 119 (full area, not 2-short)" } else { bad "active width $w too small (expected ~120)" }
    if ($h -ge 38)  { ok "active height ($h) >= 38 (full area, not 2-short)" } else { bad "active height $h too small (expected ~39)" }
  } else { bad "could not parse size from: $activeLine" }

  # Unzoom and verify it shrinks back
  & $exe -L $session resize-pane -Z -t "${session}:0" | Out-Null
  Start-Sleep -Milliseconds 200
  $unz = & $exe -L $session list-panes -t "${session}:0" -F "#{pane_index} #{pane_active} #{pane_width}x#{pane_height}"
  $u = $unz | Where-Object { $_ -match '^\d+ 1 ' } | Select-Object -First 1
  if ($u -match '(\d+)x(\d+)$') {
    $uw = [int]$Matches[1]; $uh = [int]$Matches[2]
    if ($uw -lt 120) { ok "unzoom shrinks active width back ($uw < 120)" } else { bad "unzoom did not shrink width" }
  }
}
finally {
  & $exe -L $session kill-server 2>$null | Out-Null
}

Write-Host "`nPR347 zoom-PTY: $pass passed, $fail failed" -ForegroundColor (@{$true='Green';$false='Red'}[$fail -eq 0])
if ($fail -gt 0) { exit 1 }
