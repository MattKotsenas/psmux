<#
.SYNOPSIS
  Fails when a psmux sub crate changed under a version that is already on crates.io.

.DESCRIPTION
  crates.io versions are immutable. If portable-pty-psmux or vt100-psmux is
  edited without a version bump, `cargo publish -p <sub crate>` reports
  "already exists" and the main crate is then verified against the OLD
  published sub crate, which fails to compile (v3.3.6).

  For each sub crate this script asks crates.io whether its current version
  exists. If it does, it downloads that published .crate, packages the local
  crate with `cargo package --no-verify`, and compares the two src/ trees
  (line endings normalised). Any difference means the sub crate must be
  bumped before release. Other packaged files (README, examples, ...) are
  compared too but only reported as warnings. Cargo.toml, Cargo.toml.orig,
  Cargo.lock and .cargo_vcs_info.json are ignored because cargo rewrites them.

  Run it from anywhere inside the repository:
    pwsh -File scripts/check_subcrate_divergence.ps1

  Exit code 0 when every sub crate is either unpublished at its version or
  identical to the published one, 1 when any diverged, 2 on a tool error.
#>
#Requires -Version 7
[CmdletBinding()]
param(
    [string[]]$Crates = @('portable-pty-psmux', 'vt100-psmux')
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$userAgent = 'psmux-release-preflight (https://github.com/psmux/psmux)'
$ignored = @('Cargo.toml', 'Cargo.toml.orig', 'Cargo.lock', '.cargo_vcs_info.json')

$work = Join-Path ([IO.Path]::GetTempPath()) ("psmux-subcrate-check-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

function Expand-Crate([string]$crateFile, [string]$dest) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    # A .crate is a gzip tarball; tar ships with Windows 10+ and every CI image.
    $tar = 'tar'
    if ($IsWindows -and (Test-Path "$env:SystemRoot\System32\tar.exe")) { $tar = "$env:SystemRoot\System32\tar.exe" }
    & $tar -xzf $crateFile -C $dest
    if ($LASTEXITCODE -ne 0) { throw "tar could not extract $crateFile" }
    $top = Get-ChildItem -Path $dest -Directory | Select-Object -First 1
    if (-not $top) { throw "$crateFile has no top level directory" }
    return $top.FullName
}

function Get-FileTable([string]$root) {
    $table = @{}
    Get-ChildItem -Path $root -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        if ($ignored -contains $rel) { return }
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        # Normalise CRLF to LF so a Windows checkout with autocrlf compares
        # equal to a crate packaged from an LF checkout.
        $text = [Text.Encoding]::Latin1.GetString($bytes).Replace("`r`n", "`n")
        $norm = [Text.Encoding]::Latin1.GetBytes($text)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($norm))
        $table[$rel] = $hash
    }
    return $table
}

$exit = 0
try {
    $meta = & cargo metadata --no-deps --format-version 1 --manifest-path (Join-Path $repoRoot 'Cargo.toml') | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'cargo metadata failed' }

    foreach ($name in $Crates) {
        $pkg = $meta.packages | Where-Object { $_.name -eq $name }
        if (-not $pkg) { throw "workspace has no package named $name" }
        $ver = $pkg.version
        Write-Output "== $name $ver"

        $apiUrl = "https://crates.io/api/v1/crates/$name/$ver"
        $published = $true
        try {
            Invoke-RestMethod -Uri $apiUrl -UserAgent $userAgent | Out-Null
        } catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -eq 404) { $published = $false } else { throw "crates.io query $apiUrl failed: $($_.Exception.Message)" }
        }
        if (-not $published) {
            Write-Output "   NOT PUBLISHED: $name $ver is not on crates.io yet, it will be published fresh."
            continue
        }

        $dir = Join-Path $work $name
        New-Item -ItemType Directory -Path $dir | Out-Null
        $remoteCrate = Join-Path $dir "published.crate"
        Invoke-WebRequest -Uri "$apiUrl/download" -UserAgent $userAgent -OutFile $remoteCrate

        $pkgOut = & cargo package -p $name --allow-dirty --no-verify --manifest-path (Join-Path $repoRoot 'Cargo.toml') 2>&1
        if ($LASTEXITCODE -ne 0) { $pkgOut | Write-Output; throw "cargo package -p $name failed" }
        $targetDir = $meta.target_directory
        $localCrate = Join-Path $targetDir "package/$name-$ver.crate"
        if (-not (Test-Path $localCrate)) { throw "cargo package did not produce $localCrate" }

        $remoteRoot = Expand-Crate $remoteCrate (Join-Path $dir 'published')
        $localRoot = Expand-Crate $localCrate (Join-Path $dir 'local')
        $remote = Get-FileTable $remoteRoot
        $local = Get-FileTable $localRoot

        $srcDiff = @()
        $otherDiff = @()
        foreach ($rel in (@($remote.Keys) + @($local.Keys) | Sort-Object -Unique)) {
            $r = $remote[$rel]; $l = $local[$rel]
            if ($r -eq $l) { continue }
            $why = if (-not $r) { 'only in local' } elseif (-not $l) { 'only in published' } else { 'content differs' }
            $line = "$rel ($why)"
            if ($rel -like 'src/*') { $srcDiff += $line } else { $otherDiff += $line }
        }

        foreach ($o in $otherDiff) { Write-Output "   warning: non source file differs: $o" }
        if ($srcDiff.Count -gt 0) {
            Write-Output "   DIVERGED: $($srcDiff.Count) file(s) under src/ differ from the published $name ${ver}:"
            $srcDiff | Select-Object -First 40 | ForEach-Object { Write-Output "     $_" }
            if ($srcDiff.Count -gt 40) { Write-Output "     ... and $($srcDiff.Count - 40) more" }
            $msg = "$name $ver is already on crates.io with different sources. Bump its version in crates/$name/Cargo.toml (and Cargo.toml.orig) and in the root Cargo.toml dependency, then run cargo update -p $name."
            if ($env:GITHUB_ACTIONS -eq 'true') { Write-Output "::error::$msg" } else { Write-Output "   ERROR: $msg" }
            $exit = 1
        } else {
            Write-Output "   IDENTICAL: src/ matches the published $name $ver, publishing will be skipped as already exists."
        }
    }
} catch {
    $msg = "sub crate divergence check could not run: $($_.Exception.Message)"
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Output "::error::$msg" } else { Write-Output "ERROR: $msg" }
    $exit = 2
} finally {
    Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($exit -eq 0) { Write-Output 'Sub crate check passed.' } else { Write-Output 'Sub crate check FAILED.' }
exit $exit
