# Issue #706 (noted there): `set -g copy-mode-line-numbers <mode>` in a config
# file was reported as "unknown option" although the option exists and the value
# took effect. Three sibling options read back the same way had the same false
# warning. tmux declares copy-mode-line-numbers as a CHOICE option, so a value
# outside off/default/absolute/relative/hybrid is refused, from a config and
# from `set` alike.

$ErrorActionPreference = "Continue"
$PSMUX = if ($env:PSMUX_TEST_BIN) { $env:PSMUX_TEST_BIN } else { (Get-Command psmux -EA Stop).Source }
$NS = if ($env:PSMUX_TEST_NS) { $env:PSMUX_TEST_NS } else { "i706ln" }

$script:TestsPassed = 0
$script:TestsFailed = 0
function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor Cyan }

foreach ($v in 'PSMUX_SESSION','PSMUX_TARGET_SESSION','PSMUX_PANE','TMUX','TMUX_PANE','PSMUX') {
    Remove-Item "env:$v" -EA SilentlyContinue
}
$savedDataDir = $env:PSMUX_DATA_DIR
$root = Join-Path $env:TEMP "psmux_i706_ln"
Remove-Item -Recurse -Force $root -EA SilentlyContinue
New-Item -ItemType Directory -Force $root | Out-Null
$env:PSMUX_DATA_DIR = Join-Path $root "data"
New-Item -ItemType Directory -Force $env:PSMUX_DATA_DIR | Out-Null

Write-Host ""
Write-Host "=== Issue #706: copy-mode-line-numbers in a config file ===" -ForegroundColor Magenta
Write-Info "Binary: $PSMUX"

$cfg = Join-Path $root "ln.conf"
Set-Content -Path $cfg -Encoding UTF8 -Value @(
    "set -g copy-mode-line-numbers relative",
    "setw -g copy-mode-line-numbers hybrid",
    "set -g copy-mode-line-number-style fg=red",
    "set -g copy-mode-current-line-number-style fg=blue",
    "set -g pane-border-lines double"
)
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
$out = (& $PSMUX -L $NS -f $cfg new-session -d -s w 2>&1 | Out-String)
if ($out -match 'unknown option') {
    Write-Fail "a known option was reported as unknown:"
    ($out -split "`n") | Where-Object { $_ -match 'unknown option' } | ForEach-Object { Write-Info $_.Trim() }
} else {
    Write-Pass "no option in the config is reported as unknown"
}
$v = (& $PSMUX -L $NS show -gwv copy-mode-line-numbers 2>&1 | Out-String).Trim()
if ($v -eq 'hybrid') { Write-Pass "the config value took effect (hybrid)" } else { Write-Fail "copy-mode-line-numbers is '$v', expected hybrid" }
$v = (& $PSMUX -L $NS show -gv pane-border-lines 2>&1 | Out-String).Trim()
if ($v -eq 'double') { Write-Pass "pane-border-lines took effect (double)" } else { Write-Fail "pane-border-lines is '$v', expected double" }

# `set` with a value outside the choices is refused and the old value stands.
$err = (& $PSMUX -L $NS set -g copy-mode-line-numbers bogus 2>&1 | Out-String).Trim()
$rc = $LASTEXITCODE
$v = (& $PSMUX -L $NS show -gwv copy-mode-line-numbers 2>&1 | Out-String).Trim()
if ($rc -ne 0 -and $err -match 'bogus' -and $v -eq 'hybrid') {
    Write-Pass "set refuses 'bogus' (rc=${rc}, $err) and keeps hybrid"
} else {
    Write-Fail "set accepted 'bogus': rc=$rc err='$err' value now '$v'"
}
& $PSMUX -L $NS kill-server 2>&1 | Out-Null

# A bad value in a config is named as a bad value, not as an unknown option.
$cfgBad = Join-Path $root "bad.conf"
Set-Content -Path $cfgBad -Encoding UTF8 -Value "set -g copy-mode-line-numbers bogus"
$out = (& $PSMUX -L $NS -f $cfgBad new-session -d -s w 2>&1 | Out-String)
if ($out -match 'copy-mode-line-numbers' -and $out -match 'bogus' -and $out -notmatch 'unknown option') {
    Write-Pass "a bad value in a config is reported as a bad value"
} else {
    Write-Fail "bad value report: '$($out.Trim())'"
}
& $PSMUX -L $NS kill-server 2>&1 | Out-Null
# A kill-server right after a start can miss the standby the server spawns a
# moment later; sweep again before the data directory goes.
Start-Sleep -Seconds 2
& $PSMUX -L $NS kill-server 2>&1 | Out-Null

Remove-Item -Recurse -Force $root -EA SilentlyContinue
if ($null -ne $savedDataDir) { $env:PSMUX_DATA_DIR = $savedDataDir } else { Remove-Item env:PSMUX_DATA_DIR -EA SilentlyContinue }
Write-Host ""
Write-Host "  Passed: $script:TestsPassed  Failed: $script:TestsFailed"
exit $(if ($script:TestsFailed -gt 0) { 1 } else { 0 })
