# Issue #58: Verify leblocks' claim that the theme plugin's $separator option
# "doesn't matter, it doesn't change anything in the config".
#
# Method: run the REAL everforest plugin .ps1 against a REAL psmux session with
# @everforest-separator set to each documented value (arrow|rounded|slant), then
# read back the resulting status-* / window-status-* options and compare.
# If they are byte-for-byte identical across all separator values, the option is
# a proven no-op end-to-end.

$ErrorActionPreference = "Continue"
# Decode psmux stdout (powerline separator glyphs are U+E0Bx PUA chars) as UTF-8
# so the config comparison is on true bytes, not codepage-mangled text (same fix
# as test_issue263_nested / the _fixed sibling).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue58_sep"
$psmuxDir = "$env:USERPROFILE\.psmux"
$PLUGIN_BASE = "$env:USERPROFILE\.psmux\plugins\psmux-plugins"
$PLUGIN = "$PLUGIN_BASE\psmux-theme-everforest\psmux-theme-everforest.ps1"
$script:Pass = 0; $script:Fail = 0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

# The theme .ps1 fixture is an external psmux-plugins checkout. Use the durable
# ~\.psmux\plugins location (same fixture as test_real_plugins.ps1, which
# survives Windows Temp cleanup) and auto-clone it if missing.
if (-not (Test-Path $PLUGIN_BASE)) {
    Write-Host "[INFO] Cloning psmux-plugins repo into $PLUGIN_BASE ..." -ForegroundColor Cyan
    git clone https://github.com/psmux/psmux-plugins $PLUGIN_BASE 2>&1 | Out-Null
}
# Guard on the actual .ps1 FILE: with the fixture absent, "identical config
# across separator values" would just be three runs of psmux defaults, which
# would falsely prove leblocks' no-op claim. Skip instead.
if (-not (Test-Path $PLUGIN)) {
    Write-Host "[SKIP] psmux-plugins theme checkout not present at $PLUGIN (clone https://github.com/psmux/psmux-plugins there to run this suite)" -ForegroundColor Yellow
    exit 0
}

function Cleanup { & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null; Start-Sleep -Milliseconds 400; Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue }

Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session create failed"; exit 1 }

# Capture the rendered config options that the plugin sets, as one blob
function Get-ThemeConfig {
    $keys = @('status-left','status-right','window-status-format','window-status-current-format','status-style')
    $sb = New-Object System.Text.StringBuilder
    foreach ($k in $keys) {
        $v = (& $PSMUX show-options -g -v $k -t $SESSION 2>&1 | Out-String).Trim()
        [void]$sb.AppendLine("$k=$v")
    }
    return $sb.ToString()
}

$results = @{}
foreach ($sep in @('arrow','rounded','slant')) {
    & $PSMUX set-option -g @everforest-separator $sep -t $SESSION 2>&1 | Out-Null
    # Run the real plugin script; it reads the option and re-applies all status formats
    & pwsh -NoProfile -File $PLUGIN 2>&1 | Out-Null
    # Capture the plugin's exit code immediately, before any psmux call
    # overwrites $LASTEXITCODE: a plugin that failed to launch would leave the
    # config untouched across all three separator values, and byte-identical
    # defaults must never masquerade as "separator is a no-op".
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "plugin did not execute (exit $LASTEXITCODE) for separator=$sep"
    }
    Start-Sleep -Milliseconds 500
    $cfg = Get-ThemeConfig
    $results[$sep] = $cfg
    # hash for compact comparison
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($cfg)
    $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $hex = ($sha | ForEach-Object { $_.ToString('x2') }) -join ''
    Write-Host ("[separator=$sep] config sha256 = " + $hex.Substring(0,16) + "...")
}

Write-Host "`n=== Comparison ===" -ForegroundColor Cyan
$arrow = $results['arrow']; $rounded = $results['rounded']; $slant = $results['slant']

# leblocks claimed the @<theme>-separator option "doesn't change anything in the
# config". The product REFUTES that: arrow/rounded/slant each select a distinct
# powerline separator glyph (U+E0B0 / U+E0B4 / U+E0B8), so each produces a
# DISTINCT config end-to-end. The option working is the correct behavior, so a
# distinct config per value is the PASS condition; byte-identical output would be
# the real no-op bug.
if ($arrow -ne $rounded -and $rounded -ne $slant -and $arrow -ne $slant) {
    Write-Pass "separator option is effective: arrow/rounded/slant each produce a distinct config (leblocks' 'no-op' claim refuted)"
} else {
    Write-Fail "separator appears to be a no-op: some of arrow/rounded/slant produced byte-identical config"
    Write-Host "--- arrow ---";   Write-Host $arrow
    Write-Host "--- rounded ---"; Write-Host $rounded
    Write-Host "--- slant ---";   Write-Host $slant
}

# Also prove what separator glyph (if any) actually ends up in the active config
$sl = (& $PSMUX show-options -g -v status-left -t $SESSION 2>&1 | Out-String)
Write-Host "`nActive status-left codepoints >U+2000:" -ForegroundColor Yellow
$cps = ($sl.ToCharArray() | Where-Object { [int][char]$_ -gt 0x2000 } | ForEach-Object { 'U+{0:X4}' -f [int][char]$_ }) -join ' '
if ($cps) { Write-Host "  $cps" } else { Write-Host "  (none -- no separator glyph present)" }

Cleanup
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
