# injector_guard.ps1: run a compiled WriteConsoleInput injector and tell
# "the keys never left the harness" apart from a psmux result.
#
# WHY THIS EXISTS (sweep 2026-10-01_01-53-14)
# Microsoft Defender cloud protection pushed a FastPath dynamic signature,
# Trojan:Win32/Bearfoos.A!ml, for three freshly compiled copies of
# tests\injector.cs and quarantined each one IN THE MIDDLE of its suite:
#
#   05:57:59  psmux_588_injector.exe   test_issue588_esc_after_sendkeys
#   06:00:45  psmux_injector_596.exe   test_issue596_copy_scroll_keys
#   06:27:27  psmux_injector_612.exe   test_issue612_copy_search_scrollback
#
# (Defender Operational events 1116/1117 and 2010 at those exact seconds;
# MPLog shows the SDN cloud query for each hash answered with the verdict.)
# Every later `& $injector ...` failed with ERROR_VIRUS_INFECTED (225), then
# with CommandNotFound once the file was gone. PowerShell treats both as
# non terminating, the suites ran on, and judged psmux on keys that were
# never sent: 596 scored ten product FAILs (plus one vacuous PASS on an
# "inert keys" check), 612 one, and 588 a "#588 REGRESSION" because its
# delivery oracle read a STALE %TEMP%\psmux_inject.log left by an earlier,
# successful injection.
#
# Invoke-GuardedInjector closes both holes: it deletes the shared log before
# every run (so the log can only describe THIS injection), and it treats a
# launch failure as a harness condition, recording the reason together with
# any Defender detection for that file in $script:InjectorBlocked.

$script:InjectorBlocked = $null
$script:InjectorLog     = Join-Path $env:TEMP 'psmux_inject.log'

# Defender detections (event 1116) naming this file since $Since. Empty when
# there are none or the log cannot be read; never throws.
function Get-InjectorAvEvidence {
    param([string]$Path, [datetime]$Since)
    $leaf = Split-Path $Path -Leaf
    $hits = @()
    try {
        $ev = Get-WinEvent -ErrorAction Stop -FilterHashtable @{
            LogName   = 'Microsoft-Windows-Windows Defender/Operational'
            Id        = 1116
            StartTime = $Since.AddMinutes(-2)
        }
        foreach ($e in $ev) {
            if ($e.Message -notlike "*$leaf*") { continue }
            $name = ([regex]'Name:\s*(\S+)').Match($e.Message).Groups[1].Value
            $hits += ("Defender detected {0} in {1} at {2}" -f $name, $leaf, $e.TimeCreated.ToString('HH:mm:ss'))
        }
    } catch { }
    return @($hits | Select-Object -Unique)
}

# Runs the injector once. Returns $true when the process ran (and, with
# -RequireDelivery, when its log shows at least one accepted key record);
# $false otherwise, in which case $script:InjectorBlocked holds the evidence
# and every later call returns $false without trying again.
function Invoke-GuardedInjector {
    param([string]$Injector, $ClientPid, [string]$Keys, [switch]$RequireDelivery)
    # Cleared first, even when the injector is already known to be blocked, so
    # a log from an earlier successful run can never pass for this one.
    Remove-Item -LiteralPath $script:InjectorLog -Force -ErrorAction SilentlyContinue
    if ($script:InjectorBlocked) { return $false }
    $t0  = Get-Date
    $why = $null
    if (-not (Test-Path -LiteralPath $Injector)) {
        $why = "the file is gone"
    } else {
        try {
            $out = & $Injector $ClientPid $Keys 2>&1
            foreach ($o in @($out)) {
                if ($o -is [System.Management.Automation.ErrorRecord]) { $why = $o.Exception.Message; break }
            }
        } catch {
            $why = $_.Exception.Message
        }
    }
    if (-not $why -and $RequireDelivery) {
        # The injector logs one `ok=True` line per key record WriteConsoleInput
        # accepted. A run without one (AttachConsole refused, CONIN$ denied)
        # sent nothing, so whatever psmux shows next is not about these keys.
        $ilog = Get-InjectorLog
        if ($ilog -notmatch 'ok=True') {
            $why = "it ran but no key record was accepted (log: " + (($ilog -replace '\s+', ' ').Trim()) + ")"
        }
    }
    if (-not $why) { return $true }

    # Drop the "At <script>:<line> char:<n> + ..." position tail PowerShell
    # appends to an ApplicationFailedException message.
    $why = (($why -replace '\s+', ' ') -replace '\.?\s*At [A-Za-z]:\\.*$', '').Trim()
    $av  = @(Get-InjectorAvEvidence -Path $Injector -Since $t0.AddMinutes(-30))
    $script:InjectorBlocked = "injector $(Split-Path $Injector -Leaf) could not run ($why)" +
        $(if ($av.Count) { "; " + ($av -join '; ') } else { "" })
    return $false
}

# The log the injector wrote for the LAST guarded run, or "" when it wrote
# none. A `vk=` line in it is the proof that key records reached the console.
function Get-InjectorLog {
    if (Test-Path -LiteralPath $script:InjectorLog) { return (Get-Content -LiteralPath $script:InjectorLog -Raw) }
    return ""
}
