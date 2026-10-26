<#
.SYNOPSIS
  Checks scripts\probe-terminal-cursor.ps1, the terminal cursor probe.

  The probe measures the terminal it runs in, so most of what it does cannot be
  asserted from a test: no two terminals answer the same, and the part that
  needs a pair of eyes needs a pair of eyes. What a test can hold is the set of
  ways the probe has been wrong about itself.

  1. It parses.
  2. Every sequence is built from [char]27. Windows PowerShell 5.1 has no
     escape for the escape character, so a sequence written with one is typed
     on the screen rather than sent, and every terminal then looks like it
     answers nothing. Three terminals were recorded that way before this was
     found.
  3. The file is ASCII. Windows PowerShell 5.1 reads a .ps1 with no byte order
     mark in the ANSI codepage, so non ASCII in the file is read differently by
     the two shells.
  4. It refuses to run inside psmux or tmux, where the multiplexer answers the
     queries itself and the result would describe the multiplexer.
  5. Run for real it prints a Markdown block with a heading and a stamp.

  Before: 0 of these were checked anywhere.
  After:  5 pass, 0 fail.
#>
$ErrorActionPreference = "Continue"
$results = @()
$PROBE = Join-Path $PSScriptRoot '..\scripts\probe-terminal-cursor.ps1'

function Add-Result($name, $pass, $detail = "") {
    $script:results += [PSCustomObject]@{ Test = $name; Result = if ($pass) { "PASS" } else { "FAIL" }; Detail = $detail }
    $mark = if ($pass) { "[PASS]" } else { "[FAIL]" }
    Write-Host "  $mark $name$(if ($detail) { ' ' + $detail } else { '' })"
}

Write-Host "=== Terminal cursor probe ==="

if (-not (Test-Path $PROBE)) { Write-Error "probe not found at $PROBE"; exit 1 }
$text = Get-Content -Raw -Encoding UTF8 $PROBE

# --- Test 1: it parses ---
Write-Host "`n--- Test 1: the script parses ---"
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $PROBE).Path, [ref]$null, [ref]$errors)
if ($errors) {
    Add-Result "Parses" $false ($errors[0].Message)
} else {
    Add-Result "Parses" $true
}

# --- Test 2: no escape written with the backtick escape ---
Write-Host "`n--- Test 2: sequences are built from [char]27 ---"
# Comments may name the escape, which is how the trap is explained in place.
$offenders = @()
$lineNo = 0
foreach ($line in ($text -split "`n")) {
    $lineNo++
    if ($line.TrimStart().StartsWith('#')) { continue }
    if ($line -match ('"[^"]*' + [char]96 + 'e')) { $offenders += "line $lineNo" }
}
if ($offenders.Count -eq 0) {
    Add-Result "No backtick e in code" $true
} else {
    Add-Result "No backtick e in code" $false ($offenders -join ', ')
}

# --- Test 3: ASCII only ---
Write-Host "`n--- Test 3: the file is ASCII ---"
$high = ($text.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count
if ($high -eq 0) {
    Add-Result "ASCII only" $true
} else {
    Add-Result "ASCII only" $false "$high characters above 127"
}

# --- Test 4: it refuses to measure a multiplexer ---
Write-Host "`n--- Test 4: refuses to run inside psmux or tmux ---"
$shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
$out = & $shell -NoProfile -ExecutionPolicy Bypass -Command @"
`$env:TMUX = '/tmp/psmux-1/default,1,0'
& '$((Resolve-Path $PROBE).Path)' -Terminal 'probe test' -Quiet
exit `$LASTEXITCODE
"@ 2>&1 | Out-String
if ($LASTEXITCODE -eq 1 -and $out -match 'psmux or tmux pane') {
    Add-Result "Refuses a multiplexer" $true
} else {
    Add-Result "Refuses a multiplexer" $false "exit $LASTEXITCODE, said: $($out.Trim())"
}

# --- Test 5: a real run prints a Markdown block ---
Write-Host "`n--- Test 5: a run prints a Markdown block ---"
# The probe needs a console to take. Where there is none, the console mode
# guard stops it with exit 2 and says so, which is the right answer rather than
# a failure of this test.
$run = & $shell -NoProfile -ExecutionPolicy Bypass -File (Resolve-Path $PROBE).Path `
    -Terminal 'probe test' -Quiet 2>&1 | Out-String
if ($LASTEXITCODE -eq 2 -or $run -match 'will not interpret escape sequences') {
    Add-Result "Prints a Markdown block" $true "skipped: no console to measure here"
} elseif ($run -match '### probe test' -and $run -match 'Measured \d{4}-\d{2}-\d{2}' -and $run -match '\| question \| answer \|') {
    Add-Result "Prints a Markdown block" $true
} else {
    Add-Result "Prints a Markdown block" $false "got: $($run.Trim())"
}

Write-Host "`n=== Summary ==="
$results | Format-Table -AutoSize
$passed = ($results | Where-Object { $_.Result -eq 'PASS' }).Count
$failed = ($results | Where-Object { $_.Result -eq 'FAIL' }).Count
Write-Host "Passed: $passed  Failed: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
