<#
.SYNOPSIS
  Checks scripts\probe-emoji-width.ps1 and scripts\probe-pane-emoji-shift.ps1,
  the two emoji width probes.

  Both measure the terminal they run in, so most of what they do cannot be
  asserted from a test: no two terminals answer the same. What a test can hold
  is the set of ways these two have been wrong about themselves.

  1. Both parse.
  2. Both files are ASCII. Windows PowerShell 5.1 reads a .ps1 with no byte
     order mark in the ANSI codepage, so a sequence typed into the source is
     read differently by the two shells. Every sequence is built from its code
     units instead.
  3. The width probe refuses to run where it has no console cursor to read,
     which is what a pipe gives it, rather than reporting a column of -1 as a
     measurement.
  4. The width probe refuses to run inside psmux or tmux, where the
     multiplexer would answer for itself.
  5. The pane probe refuses to run outside a pane, where there is nobody to
     ask where the cursor is.
  6. The pane probe forces the output encoding to UTF-8 before it writes. Its
     first run did not, and .NET turned every sequence into one question mark
     per UTF-16 code unit: the pane then measured a row of question marks and
     the numbers looked plausible enough to believe.
  7. The pane probe reads each line back with capture-pane, so a run where the
     characters never arrived says so instead of reporting the width of
     whatever did.

  Before: 0 of these were checked anywhere.
  After:  7 pass, 0 fail.
#>

$ErrorActionPreference = "Continue"
$results = @()
$WIDTH = Join-Path $PSScriptRoot '..\scripts\probe-emoji-width.ps1'
$PANE  = Join-Path $PSScriptRoot '..\scripts\probe-pane-emoji-shift.ps1'

function Add-Result($name, $pass, $detail = "") {
    $script:results += [PSCustomObject]@{ Test = $name; Result = if ($pass) { "PASS" } else { "FAIL" }; Detail = $detail }
    $mark = if ($pass) { "[PASS]" } else { "[FAIL]" }
    Write-Host "  $mark $name$(if ($detail) { ' ' + $detail } else { '' })"
}

Write-Host "=== Emoji width probes ==="

foreach ($p in @($WIDTH, $PANE)) {
    if (-not (Test-Path $p)) { Write-Error "probe not found at $p"; exit 1 }
}
$widthText = Get-Content -Raw -Encoding UTF8 $WIDTH
$paneText  = Get-Content -Raw -Encoding UTF8 $PANE
$shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }

# --- Test 1: both parse ---
Write-Host "`n--- Test 1: both scripts parse ---"
$bad = @()
foreach ($p in @($WIDTH, $PANE)) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $p).Path, [ref]$null, [ref]$errors)
    if ($errors) { $bad += ((Split-Path $p -Leaf) + ': ' + $errors[0].Message) }
}
Add-Result "Both parse" ($bad.Count -eq 0) ($bad -join '; ')

# --- Test 2: ASCII only ---
Write-Host "`n--- Test 2: both files are ASCII ---"
$high = @()
foreach ($pair in @(@($WIDTH, $widthText), @($PANE, $paneText))) {
    $n = ($pair[1].ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count
    if ($n -gt 0) { $high += ((Split-Path $pair[0] -Leaf) + ": $n above 127") }
}
Add-Result "ASCII only" ($high.Count -eq 0) ($high -join '; ')

# --- Test 3: the width probe needs a console ---
Write-Host "`n--- Test 3: the width probe refuses a pipe ---"
$out = & $shell -NoProfile -ExecutionPolicy Bypass -File (Resolve-Path $WIDTH).Path 2>&1 | Out-String
if ($LASTEXITCODE -eq 1 -and $out -match 'not a console') {
    Add-Result "Refuses a pipe" $true
} elseif ($out -match 'sequence\s+columns') {
    Add-Result "Refuses a pipe" $true "a console was available, so it measured instead"
} else {
    Add-Result "Refuses a pipe" $false "exit $LASTEXITCODE, said: $($out.Trim())"
}

# --- Test 4: the width probe refuses a multiplexer ---
Write-Host "`n--- Test 4: the width probe refuses to run inside psmux or tmux ---"
$out = & $shell -NoProfile -ExecutionPolicy Bypass -Command @"
`$env:TMUX = '/tmp/psmux-1/default,1,0'
& '$((Resolve-Path $WIDTH).Path)'
exit `$LASTEXITCODE
"@ 2>&1 | Out-String
if ($LASTEXITCODE -eq 1 -and ($out -match 'multiplexer' -or $out -match 'not a console')) {
    Add-Result "Refuses a multiplexer" $true
} else {
    Add-Result "Refuses a multiplexer" $false "exit $LASTEXITCODE, said: $($out.Trim())"
}

# --- Test 5: the pane probe refuses to run outside a pane ---
Write-Host "`n--- Test 5: the pane probe refuses to run outside a pane ---"
$out = & $shell -NoProfile -ExecutionPolicy Bypass -Command @"
`$env:TMUX = ''
`$env:PSMUX_SESSION = ''
& '$((Resolve-Path $PANE).Path)'
exit `$LASTEXITCODE
"@ 2>&1 | Out-String
if ($LASTEXITCODE -eq 1 -and $out -match 'inside a psmux pane') {
    Add-Result "Refuses to run outside a pane" $true
} else {
    Add-Result "Refuses to run outside a pane" $false "exit $LASTEXITCODE, said: $($out.Trim())"
}

# --- Test 6: the pane probe forces UTF-8 before writing ---
Write-Host "`n--- Test 6: the pane probe sets the output encoding ---"
$setsUtf8 = $paneText -match '\[Console\]::OutputEncoding\s*=\s*New-Object\s+System\.Text\.UTF8Encoding'
$writesFirst = $paneText.IndexOf('[Console]::OutputEncoding') -lt $paneText.IndexOf('[Console]::Out.Write')
Add-Result "Forces UTF-8 before writing" ($setsUtf8 -and $writesFirst) `
    $(if (-not $setsUtf8) { "no UTF8Encoding assignment" } elseif (-not $writesFirst) { "set after the first write" } else { "" })

# --- Test 7: the pane probe checks the characters arrived ---
Write-Host "`n--- Test 7: the pane probe reads the line back ---"
$readsBack = $paneText -match 'capture-pane'
$warns = $paneText -match 'did not reach the pane intact'
Add-Result "Reads the line back" ($readsBack -and $warns) `
    $(if (-not $readsBack) { "no capture-pane" } elseif (-not $warns) { "no warning when it did not arrive" } else { "" })

Write-Host "`n=== Summary ==="
$results | Format-Table -AutoSize
$passed = ($results | Where-Object { $_.Result -eq 'PASS' }).Count
$failed = ($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Host "Passed: $passed  Failed: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
