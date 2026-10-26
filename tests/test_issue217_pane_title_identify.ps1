# Issue #217: pane_title should default to hostname, not "pane %N"
# IDENTIFICATION TEST - proves the bug exists by comparing actual vs expected behavior
#
# tmux behavior (from man page, NAMES AND TITLES section):
#   "When a pane is first created, its title is the hostname."
#   pane_title (alias #T) = Title of pane (can be set by application)
#   status-right default includes "#{=21:pane_title}" which shows hostname in quotes
#
# psmux actual behavior:
#   pane_title = "pane %1" (generic pane identifier)
#   #T = window name (e.g. "pwsh") instead of pane_title
#   OSC title escape sequences do NOT update pane_title

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "id_issue217"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:BugsConfirmed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Bug($msg)  { Write-Host "  [BUG CONFIRMED] $msg" -ForegroundColor Magenta; $script:BugsConfirmed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

# === SETUP ===
Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 3

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed, cannot continue"
    exit 1
}

$hostname = [System.Net.Dns]::GetHostName()

Write-Host "`n=== Issue #217 Identification Tests ===" -ForegroundColor Cyan
Write-Host "  Expected hostname: $hostname" -ForegroundColor DarkGray

# === TEST 1: Default pane_title should be hostname ===
Write-Host "`n[Test 1] Default pane_title value" -ForegroundColor Yellow
$paneTitle = (& $PSMUX display-message -t $SESSION -p '#{pane_title}' 2>&1 | Out-String).Trim()
Write-Host "  Actual pane_title: '$paneTitle'" -ForegroundColor DarkGray
Write-Host "  Expected (tmux): '$hostname'" -ForegroundColor DarkGray

if ($paneTitle -eq $hostname) {
    Write-Pass "pane_title defaults to hostname (tmux compatible)"
} elseif ($paneTitle -match "^pane %\d+$") {
    Write-Bug "pane_title defaults to '$paneTitle' instead of hostname '$hostname'"
} else {
    Write-Fail "pane_title is '$paneTitle', expected hostname '$hostname'"
}

# === TEST 2: #T alias should resolve to pane_title, not window_name ===
Write-Host "`n[Test 2] #T format alias resolution" -ForegroundColor Yellow
$hashT = (& $PSMUX display-message -t $SESSION -p '#T' 2>&1 | Out-String).Trim()
$windowName = (& $PSMUX display-message -t $SESSION -p '#{window_name}' 2>&1 | Out-String).Trim()
Write-Host "  #T resolves to: '$hashT'" -ForegroundColor DarkGray
Write-Host "  window_name is: '$windowName'" -ForegroundColor DarkGray
Write-Host "  pane_title is: '$paneTitle'" -ForegroundColor DarkGray

if ($hashT -eq $paneTitle) {
    Write-Pass "#T resolves to pane_title (correct alias)"
} elseif ($hashT -eq $windowName -and $hashT -ne $paneTitle) {
    Write-Bug "#T resolves to window_name ('$windowName') instead of pane_title ('$paneTitle')"
} else {
    Write-Fail "#T is '$hashT', expected pane_title '$paneTitle'"
}

# === TEST 3: #{host} should return hostname ===
Write-Host "`n[Test 3] #{host} format variable" -ForegroundColor Yellow
$hostVar = (& $PSMUX display-message -t $SESSION -p '#{host}' 2>&1 | Out-String).Trim()
Write-Host "  #{host} resolves to: '$hostVar'" -ForegroundColor DarkGray

if ($hostVar -ieq $hostname) {
    Write-Pass "#{host} returns hostname correctly ('$hostVar')"
} else {
    Write-Fail "#{host} is '$hostVar', expected '$hostname'"
}

# === TEST 4: #{host_short} should return hostname (no domain) ===
Write-Host "`n[Test 4] #{host_short} format variable" -ForegroundColor Yellow
$hostShort = (& $PSMUX display-message -t $SESSION -p '#{host_short}' 2>&1 | Out-String).Trim()
$expectedShort = $hostname.Split('.')[0]
Write-Host "  #{host_short} resolves to: '$hostShort'" -ForegroundColor DarkGray

if ($hostShort -ieq $expectedShort) {
    Write-Pass "#{host_short} returns short hostname correctly ('$hostShort')"
} else {
    Write-Fail "#{host_short} is '$hostShort', expected '$expectedShort'"
}

# === TEST 5: status-right format includes pane_title ===
Write-Host "`n[Test 5] status-right format contains pane_title" -ForegroundColor Yellow
$statusRight = (& $PSMUX show-options -g -v status-right -t $SESSION 2>&1 | Out-String).Trim()
Write-Host "  status-right format: '$statusRight'" -ForegroundColor DarkGray

if ($statusRight -match "pane_title") {
    Write-Pass "status-right format references pane_title"
} else {
    Write-Fail "status-right does not reference pane_title"
}

# === TEST 6: OSC title escape sequences are GATED by allow-set-title ===
#
# This used to send OSC 2 with the option at its default and report a confirmed
# bug when pane_title did not change. That is documented, deliberate behaviour,
# not a defect: psmux ships `allow-set-title off` because PowerShell 7 rewrites
# the terminal title to the current directory on EVERY prompt, so leaving it on
# turns #{pane_title} into a churning path. See docs/pane-titles.md, the option
# table in docs/configuration.md, and the FAQ entry.
#
# So both halves of the gate are asserted: off suppresses, on propagates.
# Measured against real tmux 3.4, which has no such option at all
# ("invalid option: allow-set-title") and always tracks the title:
#   tmux printf '\033]2;TMUXMARKER\007'  ->  pane_title becomes TMUXMARKER
Write-Host "`n[Test 6] OSC title escape sequences are gated by allow-set-title" -ForegroundColor Yellow
$marker = "OSC_TEST_TITLE_217"

$optDefault = (& $PSMUX show-options -g -v allow-set-title -t $SESSION 2>&1 | Out-String).Trim()
if ($optDefault -eq "off") { Write-Pass "allow-set-title defaults to off (documented Windows default)" }
else { Write-Fail "expected allow-set-title default 'off', got '$optDefault'" }

# --- half 1: with the option OFF the title must NOT follow the escape ---
& $PSMUX send-keys -t $SESSION "Write-Host -NoNewline ([char]27 + `"]2;$marker`" + [char]7)" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$titleOptOff = (& $PSMUX display-message -t $SESSION -p '#{pane_title}' 2>&1 | Out-String).Trim()
Write-Host "  pane_title after OSC 2 with option off: '$titleOptOff'" -ForegroundColor DarkGray
if ($titleOptOff -ne $marker) {
    Write-Pass "option off suppresses the OSC title (still '$titleOptOff')"
} else {
    Write-Fail "option off did NOT suppress the OSC title: pane_title became '$titleOptOff'"
}

# --- half 2: with the option ON the title must follow the escape ---
& $PSMUX set-option -t $SESSION -g allow-set-title on 2>&1 | Out-Null
Start-Sleep -Seconds 1
$markerOn = "OSC_ON_TITLE_217"
& $PSMUX send-keys -t $SESSION "Write-Host -NoNewline ([char]27 + `"]2;$markerOn`" + [char]7)" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$titleOptOn = (& $PSMUX display-message -t $SESSION -p '#{pane_title}' 2>&1 | Out-String).Trim()
Write-Host "  pane_title after OSC 2 with option on:  '$titleOptOn'" -ForegroundColor DarkGray
if ($titleOptOn -eq $markerOn) {
    Write-Pass "allow-set-title on: OSC 2 updates pane_title (tmux behaviour)"
} else {
    Write-Fail "allow-set-title on: expected '$markerOn', got '$titleOptOn'"
}

# Restore the shipped default so the later checks see a stock session.
& $PSMUX set-option -t $SESSION -g allow-set-title off 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# === TEST 7: select-pane -T should set pane title ===
Write-Host "`n[Test 7] select-pane -T sets pane title" -ForegroundColor Yellow
$customTitle = "MyCustomTitle217"
& $PSMUX select-pane -t $SESSION -T $customTitle 2>&1 | Out-Null
Start-Sleep -Seconds 1
$titleAfterSet = (& $PSMUX display-message -t $SESSION -p '#{pane_title}' 2>&1 | Out-String).Trim()
Write-Host "  pane_title after select-pane -T: '$titleAfterSet'" -ForegroundColor DarkGray

if ($titleAfterSet -eq $customTitle) {
    Write-Pass "select-pane -T sets pane_title to '$customTitle'"
} else {
    Write-Bug "select-pane -T did not set pane_title. Got '$titleAfterSet', expected '$customTitle'"
}

# === TEST 8: Verify status bar renders pane_title in quotes ===
Write-Host "`n[Test 8] Status bar pane_title rendering" -ForegroundColor Yellow
$rendered = (& $PSMUX display-message -t $SESSION -p '"#{=21:pane_title}"' 2>&1 | Out-String).Trim()
Write-Host "  Rendered status-right pane_title portion: '$rendered'" -ForegroundColor DarkGray
Write-Host "  Expected (tmux style): `"$hostname`" (hostname in quotes)" -ForegroundColor DarkGray

# Check if it shows hostname or something else
if ($rendered -match [regex]::Escape($hostname)) {
    Write-Pass "Status bar shows hostname in pane_title"
} elseif ($rendered -match "pane %\d+") {
    Write-Bug "Status bar shows '$rendered' instead of hostname"
} else {
    Write-Host "  Note: pane_title was modified by select-pane -T, so this may show custom title" -ForegroundColor DarkGray
    if ($rendered -match [regex]::Escape($customTitle)) {
        Write-Pass "Status bar shows custom title set by select-pane -T"
    } else {
        Write-Fail "Status bar renders: '$rendered'"
    }
}

# === TEARDOWN ===
Cleanup

# === SUMMARY ===
Write-Host "`n=== Identification Results ===" -ForegroundColor Cyan
Write-Host "  Tests Passed:    $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Tests Failed:    $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "  Bugs Confirmed:  $($script:BugsConfirmed)" -ForegroundColor $(if ($script:BugsConfirmed -gt 0) { "Magenta" } else { "Green" })

if ($script:BugsConfirmed -gt 0) {
    Write-Host "`n  VERDICT: Issue #217 is CONFIRMED." -ForegroundColor Magenta
    Write-Host "  The pane_title does not default to hostname as tmux specifies." -ForegroundColor DarkGray
} else {
    Write-Host "`n  VERDICT: Issue #217 could not be reproduced." -ForegroundColor Green
}

exit $script:TestsFailed + $script:BugsConfirmed
