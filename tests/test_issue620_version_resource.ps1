# Issue #620: psmux.exe shipped with no Windows icon and an empty version
# resource. ProductName, FileDescription and FileVersion were all blank and the
# file group icon was absent, so every place Windows names a process from its
# PE resources showed a nameless generic entry: the Task Manager Description
# column, the taskbar, alt-tab, and third party consent dialogs such as the one
# 1Password raises when an application asks for unlock.
#
# The fix adds a `winresource` build-dependency and a Windows arm in build.rs
# that embeds assets\psmux.ico plus a VS_VERSIONINFO block whose version fields
# are taken from CARGO_PKG_VERSION.
#
# This test reads the resources straight back out of the built binary:
#   Part A: VS_VERSIONINFO strings (ProductName / FileDescription / versions)
#   Part B: VS_FIXEDFILEINFO numeric version agrees with the strings
#   Part C: the RT_GROUP_ICON / RT_ICON / RT_VERSION resources are in the PE
#           and the extracted icon carries the psmux artwork
#   Part D: assets\psmux.ico still has every frame size the icon needs
#
# Set PSMUX_TEST_BIN to test a non-installed binary.

$ErrorActionPreference = "Continue"

$repoRoot = Split-Path -Parent $PSScriptRoot

# PSMUX_TEST_BIN wins when set, otherwise the freshly built release binary,
# otherwise whatever psmux is on PATH.
$PSMUX = $null
if ($env:PSMUX_TEST_BIN -and (Test-Path $env:PSMUX_TEST_BIN)) {
    $PSMUX = (Resolve-Path $env:PSMUX_TEST_BIN).Path
} elseif (Test-Path (Join-Path $repoRoot "target\release\psmux.exe")) {
    $PSMUX = (Resolve-Path (Join-Path $repoRoot "target\release\psmux.exe")).Path
} else {
    $cmd = Get-Command psmux -EA SilentlyContinue
    if ($cmd) { $PSMUX = $cmd.Source }
}

$script:Pass = 0; $script:Fail = 0
function Write-Pass($m) { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Info($m) { Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }

if (-not $PSMUX) {
    Write-Host "no psmux.exe found (build target\release\psmux.exe or set PSMUX_TEST_BIN)" -ForegroundColor Red
    exit 1
}

Write-Host "binary:   $PSMUX" -ForegroundColor Cyan
Write-Host "repoRoot: $repoRoot" -ForegroundColor Cyan

# The version the resource block is supposed to carry comes from Cargo.toml.
$cargoToml = Join-Path $repoRoot "Cargo.toml"
$expectedVersion = $null
$inPackage = $false
foreach ($line in (Get-Content $cargoToml)) {
    if ($line -match '^\s*\[') { $inPackage = ($line -match '^\s*\[package\]\s*$'); continue }
    if ($inPackage -and $line -match '^\s*version\s*=\s*"([^"]+)"') { $expectedVersion = $Matches[1]; break }
}
if (-not $expectedVersion) {
    Write-Fail "could not read the package version out of $cargoToml"
    Write-Host "`n=== Issue #620 results: $script:Pass passed, $script:Fail failed ===" -ForegroundColor Cyan
    exit 1
}
Write-Host "Cargo.toml version: $expectedVersion" -ForegroundColor Cyan

$vi = (Get-Item $PSMUX).VersionInfo

# ---------------------------------------------------------------------------
# Part A: VS_VERSIONINFO string table
# ---------------------------------------------------------------------------
Write-Host "`n=== Part A: version resource strings ===" -ForegroundColor Cyan

Write-Info "ProductName      = '$($vi.ProductName)'"
Write-Info "FileDescription  = '$($vi.FileDescription)'"
Write-Info "FileVersion      = '$($vi.FileVersion)'"
Write-Info "ProductVersion   = '$($vi.ProductVersion)'"
Write-Info "CompanyName      = '$($vi.CompanyName)'"
Write-Info "OriginalFilename = '$($vi.OriginalFilename)'"
Write-Info "LegalCopyright   = '$($vi.LegalCopyright)'"

if ($vi.ProductName -eq "psmux") { Write-Pass "ProductName is 'psmux'" }
else { Write-Fail "ProductName is '$($vi.ProductName)', expected 'psmux'" }

if (-not [string]::IsNullOrWhiteSpace($vi.FileDescription)) {
    Write-Pass "FileDescription is non-empty: '$($vi.FileDescription)'"
} else {
    Write-Fail "FileDescription is empty (this is the string Task Manager and 1Password show)"
}

# The reporter's dialogs render FileDescription verbatim, so it has to name the
# product, not just repeat the file name.
if ($vi.FileDescription -match 'psmux') { Write-Pass "FileDescription names psmux" }
else { Write-Fail "FileDescription '$($vi.FileDescription)' does not mention psmux" }

if ($vi.FileVersion -eq $expectedVersion) {
    Write-Pass "FileVersion '$($vi.FileVersion)' matches Cargo.toml '$expectedVersion'"
} else {
    Write-Fail "FileVersion '$($vi.FileVersion)' does not match Cargo.toml '$expectedVersion'"
}

if ($vi.ProductVersion -eq $expectedVersion) {
    Write-Pass "ProductVersion '$($vi.ProductVersion)' matches Cargo.toml '$expectedVersion'"
} else {
    Write-Fail "ProductVersion '$($vi.ProductVersion)' does not match Cargo.toml '$expectedVersion'"
}

if (-not [string]::IsNullOrWhiteSpace($vi.OriginalFilename)) {
    Write-Pass "OriginalFilename is set: '$($vi.OriginalFilename)'"
} else {
    Write-Fail "OriginalFilename is empty"
}

if (-not [string]::IsNullOrWhiteSpace($vi.LegalCopyright)) {
    Write-Pass "LegalCopyright is set: '$($vi.LegalCopyright)'"
} else {
    Write-Fail "LegalCopyright is empty"
}

# ---------------------------------------------------------------------------
# Part B: VS_FIXEDFILEINFO numeric fields
# ---------------------------------------------------------------------------
# The strings above live in the StringFileInfo block; the numeric fields are a
# separate struct and used to read 0.0.0.0. Both have to agree or tools that
# sort by version (installers, Explorer's details pane) still see nothing.
Write-Host "`n=== Part B: VS_FIXEDFILEINFO numeric version ===" -ForegroundColor Cyan

$parts = $expectedVersion -split '[.\-+]'
$expMajor = [int]$parts[0]
$expMinor = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
$expPatch = if ($parts.Count -gt 2) { [int]$parts[2] } else { 0 }

$numeric = "$($vi.FileMajorPart).$($vi.FileMinorPart).$($vi.FileBuildPart).$($vi.FilePrivatePart)"
Write-Info "FileVersionRaw    = $numeric"
Write-Info "ProductVersionRaw = $($vi.ProductMajorPart).$($vi.ProductMinorPart).$($vi.ProductBuildPart).$($vi.ProductPrivatePart)"

if ($vi.FileMajorPart -eq $expMajor -and $vi.FileMinorPart -eq $expMinor -and $vi.FileBuildPart -eq $expPatch) {
    Write-Pass "numeric file version $numeric encodes $expectedVersion"
} else {
    Write-Fail "numeric file version $numeric does not encode $expectedVersion"
}

if ($vi.ProductMajorPart -eq $expMajor -and $vi.ProductMinorPart -eq $expMinor -and $vi.ProductBuildPart -eq $expPatch) {
    Write-Pass "numeric product version encodes $expectedVersion"
} else {
    Write-Fail "numeric product version does not encode $expectedVersion"
}

# ---------------------------------------------------------------------------
# Part C: the icon resource
# ---------------------------------------------------------------------------
Write-Host "`n=== Part C: application icon ===" -ForegroundColor Cyan

Add-Type -AssemblyName System.Drawing -EA SilentlyContinue
$icon = $null
try { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($PSMUX) } catch { Write-Info "ExtractAssociatedIcon threw: $_" }

if ($icon) {
    Write-Pass "ExtractAssociatedIcon returned an icon ($($icon.Width)x$($icon.Height))"
    # The generic "no icon" fallback Windows hands back is the shell's own
    # default, so also prove the bitmap carries the psmux palette: the artwork
    # is a cyan disc, which the shell default never is.
    try {
        $bmp = $icon.ToBitmap()
        $cx = [int]($bmp.Width / 2)
        $blueish = 0
        for ($y = 0; $y -lt $bmp.Height; $y++) {
            $p = $bmp.GetPixel($cx, $y)
            if ($p.A -gt 128 -and $p.B -gt 120 -and $p.B -gt $p.R) { $blueish++ }
        }
        Write-Info "column scan: $blueish of $($bmp.Height) pixels are blue dominant"
        if ($blueish -ge 4) { Write-Pass "icon bitmap carries the psmux blue artwork" }
        else { Write-Fail "icon bitmap has no blue dominant pixels, this looks like the shell default" }
        $bmp.Dispose()
    } catch { Write-Fail "could not inspect the icon bitmap: $_" }
    $icon.Dispose()
} else {
    Write-Fail "ExtractAssociatedIcon returned nothing, the exe has no icon resource"
}

# Read the PE resource directory directly: ExtractAssociatedIcon falls back to
# the shell default for a resource-less exe, so confirm RT_GROUP_ICON (type 14)
# and RT_ICON (type 3) really are in this file.
$sig = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Psmux620Res {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr LoadLibraryEx(string f, IntPtr h, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool FreeLibrary(IntPtr h);
    delegate bool EnumResNameProc(IntPtr hModule, IntPtr type, IntPtr name, IntPtr lParam);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool EnumResourceNamesW(IntPtr hModule, IntPtr type, EnumResNameProc cb, IntPtr lParam);
    const uint LOAD_LIBRARY_AS_DATAFILE = 0x00000002;
    const uint LOAD_LIBRARY_AS_IMAGE_RESOURCE = 0x00000020;
    public static List<string> Names(string path, int resType) {
        var found = new List<string>();
        IntPtr h = LoadLibraryEx(path, IntPtr.Zero, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
        if (h == IntPtr.Zero) throw new Exception("LoadLibraryEx failed: " + Marshal.GetLastWin32Error());
        try {
            EnumResourceNamesW(h, new IntPtr(resType), (m, t, n, l) => {
                found.Add(((long)n < 0x10000) ? "#" + (long)n : Marshal.PtrToStringUni(n));
                return true;
            }, IntPtr.Zero);
        } finally { FreeLibrary(h); }
        return found;
    }
}
'@
try {
    if (-not ("Psmux620Res" -as [type])) { Add-Type -TypeDefinition $sig -Language CSharp }
    $groups = [Psmux620Res]::Names($PSMUX, 14)   # RT_GROUP_ICON
    $icons  = [Psmux620Res]::Names($PSMUX, 3)    # RT_ICON
    $vers   = [Psmux620Res]::Names($PSMUX, 16)   # RT_VERSION
    Write-Info "RT_GROUP_ICON entries: $($groups -join ', ')"
    Write-Info "RT_ICON entries ($($icons.Count)): $($icons -join ', ')"
    Write-Info "RT_VERSION entries: $($vers -join ', ')"

    if ($groups.Count -ge 1) { Write-Pass "RT_GROUP_ICON resource present" }
    else { Write-Fail "no RT_GROUP_ICON resource in the PE" }

    # assets\psmux.ico ships 16/24/32/48/64/128/256, so every frame should have
    # become its own RT_ICON.
    if ($icons.Count -ge 7) { Write-Pass "$($icons.Count) RT_ICON frames embedded (expected at least 7)" }
    else { Write-Fail "only $($icons.Count) RT_ICON frames embedded, expected at least 7" }

    if ($vers.Count -ge 1) { Write-Pass "RT_VERSION resource present" }
    else { Write-Fail "no RT_VERSION resource in the PE" }
} catch {
    Write-Fail "PE resource enumeration failed: $_"
}

# ---------------------------------------------------------------------------
# Part D: the source icon still has all its frames
# ---------------------------------------------------------------------------
Write-Host "`n=== Part D: assets\psmux.ico frame table ===" -ForegroundColor Cyan
$icoPath = Join-Path $repoRoot "assets\psmux.ico"
if (Test-Path $icoPath) {
    $bytes = [System.IO.File]::ReadAllBytes($icoPath)
    $count = [BitConverter]::ToUInt16($bytes, 4)
    $frames = @()
    for ($i = 0; $i -lt $count; $i++) {
        $o = 6 + $i * 16
        $w = $bytes[$o]; if ($w -eq 0) { $w = 256 }
        $h = $bytes[$o + 1]; if ($h -eq 0) { $h = 256 }
        $frames += "${w}x${h}"
    }
    Write-Info "frames: $($frames -join ', ')"
    $want = @(16, 24, 32, 48, 64, 128, 256)
    $missing = @()
    foreach ($s in $want) { if ($frames -notcontains "${s}x${s}") { $missing += $s } }
    if ($missing.Count -eq 0) { Write-Pass "all of $($want -join '/') present in assets\psmux.ico" }
    else { Write-Fail "assets\psmux.ico is missing frames: $($missing -join ', ')" }
} else {
    Write-Fail "assets\psmux.ico not found at $icoPath"
}

Write-Host "`n=== Issue #620 results: $script:Pass passed, $script:Fail failed ===" -ForegroundColor Cyan
if ($script:Fail -gt 0) { exit 1 }
exit 0
