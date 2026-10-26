# Issue #58: verify the separator fix across ALL psmux-plugins themes.
# For each theme: the .ps1 applies without error, sets a status bar, and (for the 8
# themes that expose @<theme>-separator) arrow/rounded/slant produce DISTINCT configs
# with the expected universal codepoints.
$ErrorActionPreference="Continue"
# This test's own pipeline decodes each theme .ps1's psmux subprocess stdout
# (`& $PSMUX show-options ... | Out-String`) and then compares literal Private
# Use Area codepoints (U+E0Bx powerline glyphs) against it. Without forcing
# this process's own console/pipeline encoding to UTF-8, PowerShell decodes
# psmux's UTF-8 bytes for those 3-byte glyphs using the ambient system
# codepage, mangling a single U+E0B4 into 3 unrelated characters (confirmed:
# U+03B5/U+00E9/U+2524) that never match any codepoint in $sepSet -- this is
# exactly why every theme reported "sep glyph none", even though psmux itself
# stores and returns the glyph correctly (verified directly: with
# [Console]::OutputEncoding forced to UTF-8, a set-option/show-options round
# trip of a raw U+E0B4 character round-trips byte-for-byte). Same fix pattern
# as test_issue263_nested.ps1.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSMUX=(Get-Command psmux).Source
$base="$env:USERPROFILE\.psmux\plugins\psmux-plugins"
# The theme .ps1 fixtures are an external psmux-plugins checkout. Use the
# durable ~\.psmux\plugins location (same fixture as test_real_plugins.ps1,
# which survives Windows Temp cleanup) and auto-clone it if missing.
if(-not(Test-Path $base)){
  Write-Host "[INFO] Cloning psmux-plugins repo into $base ..." -ForegroundColor Cyan
  git clone https://github.com/psmux/psmux-plugins $base 2>&1 | Out-Null
}
# Guard on the actual everforest .ps1 FILE (a gutted checkout can leave the
# directory behind with every .ps1 deleted); if it is still missing after the
# bootstrap there is nothing real to test, so skip instead of reporting one
# phantom failure per theme.
if(-not(Test-Path "$base\psmux-theme-everforest\psmux-theme-everforest.ps1")){
  Write-Host "[SKIP] psmux-plugins theme .ps1 fixtures not present under $base (clone https://github.com/psmux/psmux-plugins there to run this suite)" -ForegroundColor Yellow
  exit 0
}
$S="issue58_all"
$psmuxDir="$env:USERPROFILE\.psmux"
$pass=0;$fail=0
function P($m){Write-Host "  [PASS] $m" -ForegroundColor Green;$script:pass++}
function F($m){Write-Host "  [FAIL] $m" -ForegroundColor Red;$script:fail++}

& $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
& $PSMUX new-session -d -s $S; Start-Sleep -Seconds 3

# expected first status-left separator codepoint per style
$exp=@{arrow=0xE0B0;rounded=0xE0B4;slant=0xE0B8}
$sepSet=0xE0B0,0xE0B2,0xE0B4,0xE0B6,0xE0B8,0xE0BA
function FirstSep($s){foreach($ch in $s.ToCharArray()){$c=[int][char]$ch;if($sepSet -contains $c){return $c}};return $null}

$withSwitch='everforest','gruvbox','dracula','nord','tokyonight','kanagawa','onedark','rosepine'
$noSwitch='catppuccin'

Write-Host "`n=== Themes WITH @<theme>-separator ===" -ForegroundColor Cyan
foreach($t in $withSwitch){
  $ps1="$base\psmux-theme-$t\psmux-theme-$t.ps1"
  if(-not(Test-Path $ps1)){F "$t .ps1 missing";continue}
  $cfg=@{}
  $ok=$true
  foreach($sep in 'arrow','rounded','slant'){
    & $PSMUX set-option -g "@$t-separator" $sep -t $S 2>&1 | Out-Null
    $err = & pwsh -NoProfile -File $ps1 2>&1
    if($LASTEXITCODE -ne 0){ $ok=$false }
    Start-Sleep -Milliseconds 150
    $sl=(& $PSMUX show-options -g -v status-left -t $S 2>&1|Out-String).Trim()
    $cfg[$sep]=$sl
    $fs=FirstSep $sl
    if($fs -ne $exp[$sep]){ F ("{0}/{1}: sep glyph {2} != expected U+{3:X4}" -f $t,$sep,$(if($fs){'U+{0:X4}'-f $fs}else{'none'}),$exp[$sep]); $ok=$false }
  }
  $distinct = ($cfg['arrow'] -ne $cfg['rounded']) -and ($cfg['rounded'] -ne $cfg['slant']) -and ($cfg['arrow'] -ne $cfg['slant'])
  $stOn = (& $PSMUX show-options -g -v status -t $S 2>&1|Out-String).Trim()
  if($ok -and $distinct -and $stOn -eq 'on'){ P "${t}: 3 distinct styles, correct glyphs, status on" }
  elseif(-not $distinct){ F "${t}: styles not all distinct" }
}

Write-Host "`n=== Themes WITHOUT separator option ===" -ForegroundColor Cyan
foreach($t in $noSwitch){
  $ps1="$base\psmux-theme-$t\psmux-theme-$t.ps1"
  if(-not(Test-Path $ps1)){ F "$t plugin file missing at $ps1"; continue }
  $err=& pwsh -NoProfile -File $ps1 2>&1
  # Capture the plugin's exit code IMMEDIATELY: the psmux show-options calls
  # below overwrite $LASTEXITCODE, which previously let a failed plugin run
  # pass vacuously against psmux's default status options.
  $pluginExit=$LASTEXITCODE
  Start-Sleep -Milliseconds 150
  $stOn=(& $PSMUX show-options -g -v status -t $S 2>&1|Out-String).Trim()
  $sl=(& $PSMUX show-options -g -v status-left -t $S 2>&1|Out-String).Trim()
  if($pluginExit -ne 0){ F "${t}: plugin exited nonzero ($pluginExit): $err" }
  elseif($stOn -eq 'on' -and $sl.Length -gt 0){ P "${t}: applies cleanly, status on (uses hardcoded half-blocks)" }
  else{ F "${t}: failed to apply" }
}

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Write-Host "`n=== Results: Passed=$pass Failed=$fail ===" -ForegroundColor Cyan
exit $fail
