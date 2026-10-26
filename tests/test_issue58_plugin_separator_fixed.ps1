# Issue #58 FIX verification: after restoring powerline glyphs in the theme .ps1
# switch blocks, @<theme>-separator must now produce DISTINCT, NON-EMPTY config
# for arrow/rounded/slant, with the expected powerline codepoints.

$ErrorActionPreference = "Continue"
# Same encoding fix as test_issue58_all_themes.ps1 / test_issue263_nested.ps1:
# without forcing this process's own console/pipeline encoding to UTF-8,
# PowerShell mis-decodes psmux's UTF-8 output for the Private Use Area
# powerline glyphs (U+E0Bx) checked below, producing "got NONE" for every
# separator even though psmux stores/returns them correctly.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue58_fix"
$psmuxDir = "$env:USERPROFILE\.psmux"
$PLUGIN_BASE = "$env:USERPROFILE\.psmux\plugins\psmux-plugins"
$PLUGIN = "$PLUGIN_BASE\psmux-theme-everforest\psmux-theme-everforest.ps1"
$script:Pass = 0; $script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Cleanup { & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 400; Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue }

# The theme .ps1 fixture is an external psmux-plugins checkout (same fixture
# test_issue58_all_themes.ps1 depends on), now kept in the durable
# ~\.psmux\plugins location that survives Windows Temp cleanup, and
# auto-cloned if missing (same bootstrap as test_real_plugins.ps1). When the
# .ps1 is still absent after the bootstrap there is nothing real to test --
# every "got NONE" below would just be this file not being found, not a
# separator-wiring regression -- so skip instead of reporting phantom
# failures.
if (-not (Test-Path $PLUGIN_BASE)) {
    Write-Host "[INFO] Cloning psmux-plugins repo into $PLUGIN_BASE ..." -ForegroundColor Cyan
    git clone https://github.com/psmux/psmux-plugins $PLUGIN_BASE 2>&1 | Out-Null
}
if (-not (Test-Path $PLUGIN)) {
    Write-Host "[SKIP] psmux-plugins theme checkout not present at $PLUGIN (clone psmux-plugins there to run this suite)" -ForegroundColor Yellow
    exit 0
}

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session create failed"; exit 1 }

# Expected first separator codepoint of status-left per style (the $sLR glyph).
# Universal glyphs (no Nerd Font required): arrow=half-block, rounded=half-circle, slant=triangle.
$expect = @{ arrow = 0xE0B0; rounded = 0xE0B4; slant = 0xE0B8 }

function Get-Cfg {
    $keys = @('status-left','status-right','window-status-format','window-status-current-format')
    ($keys | ForEach-Object { "$_=" + ((& $PSMUX show-options -g -v $_ -t $SESSION 2>&1 | Out-String).Trim()) }) -join "`n"
}
$sepSet = 0xE0B0,0xE0B2,0xE0B4,0xE0B6,0xE0B8,0xE0BA
function First-Sep([string]$s) {
    foreach ($ch in $s.ToCharArray()) { $cp=[int][char]$ch; if ($sepSet -contains $cp) { return $cp } }
    return $null
}

$cfgs = @{}
foreach ($sep in @('arrow','rounded','slant')) {
    & $PSMUX set-option -g @everforest-separator $sep -t $SESSION 2>&1 | Out-Null
    & pwsh -NoProfile -File $PLUGIN 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    $sl = (& $PSMUX show-options -g -v status-left -t $SESSION 2>&1 | Out-String)
    $cfgs[$sep] = Get-Cfg
    $fs = First-Sep $sl
    if ($fs -eq $expect[$sep]) { Write-Pass ("separator=$sep -> status-left uses U+{0:X4} (expected U+{1:X4})" -f $fs,$expect[$sep]) }
    else { Write-Fail ("separator=$sep -> got {0} expected U+{1:X4}" -f $(if($fs){'U+{0:X4}'-f $fs}else{'NONE'}),$expect[$sep]) }
}

# All three must now differ from each other
if ($cfgs['arrow'] -ne $cfgs['rounded'] -and $cfgs['rounded'] -ne $cfgs['slant'] -and $cfgs['arrow'] -ne $cfgs['slant']) {
    Write-Pass "arrow/rounded/slant now produce 3 DISTINCT configs (separator option works)"
} else {
    Write-Fail "configs are not all distinct (separator still not fully wired)"
}

Cleanup
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
