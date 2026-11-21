#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Check Package Manager Cache Size - Northstar DevKit
.DESCRIPTION
    Reports the local package manager cache location (and size, where
    discoverable) for the project at -Path. Auto-detects npm/yarn/pnpm/bun
    from lock files (same detection used across the rest of DevKit), since
    each package manager exposes its cache info differently. Read-only:
    it asks where the cache is and adds up the files there. It does NOT run
    `npm cache verify`, which this tool used to do for npm - that command
    garbage-collects the cache and rewrites its index, and can run for
    minutes on a large one, behind a button labelled "check".
      - npm:  npm config get cache
      - pnpm: pnpm store path
      - yarn: yarn cache dir (Yarn 1), yarn config get cacheFolder (Yarn 2+)
      - bun:  no programmatic "print cache path" command; falls back to
              bun's documented, fixed per-user cache location

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
.PARAMETER Path
    The project directory whose package manager cache to inspect.
    Defaults to current directory.
.EXAMPLE
    .\Check-NpmCacheSize.ps1
    .\Check-NpmCacheSize.ps1 -Path "C:\my-project"
#>
[CmdletBinding()]
param(
    [string]$Path = "."
)

$CommonModule = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) "lib") "DevKit-Common.ps1"
if (Test-Path -LiteralPath $CommonModule) {
    . $CommonModule
} else {
    Write-Host "ERROR: Required module not found: $CommonModule" -ForegroundColor Red
    exit 1
}

Write-DevKitHeader "Package Manager Cache Size"

try {
    $targetPath = Resolve-DevKitDirectory -Path $Path
} catch {
    Write-DevKitError $_
    exit 1
}

$manager = Get-DevKitPackageManager -Path $targetPath
Write-DevKitInfo "Package manager: $($manager.Command)"

if (-not (Test-DevKitCommand $manager.Command)) {
    Write-DevKitError "$($manager.Command) is not installed or not in PATH."
    exit 1
}

# Asked from inside the project: a project-level .npmrc / .yarnrc.yml can
# move the cache, and a Yarn 2+ project pins its own yarn binary - from any
# other folder these would describe a different cache than the project uses.
$cachePath = $null
Push-Location -LiteralPath $targetPath
try {
    switch ($manager.Command) {
        "npm" { $cachePath = (npm config get cache 2>$null | Select-Object -Last 1) }
        "pnpm" { $cachePath = (pnpm store path 2>$null | Select-Object -Last 1) }
        "yarn" {
            $cachePath = (yarn cache dir 2>$null | Select-Object -Last 1)
            if ($LASTEXITCODE -ne 0 -or -not $cachePath -or -not (Test-Path -LiteralPath $cachePath)) {
                # Yarn 2+ (berry) has no 'cache dir' command.
                $cachePath = (yarn config get cacheFolder 2>$null | Select-Object -Last 1)
            }
        }
        "bun" {
            # bun has no programmatic "print cache path" command; its cache
            # lives under a fixed, documented per-user location on Windows.
            $cachePath = Join-Path $env:USERPROFILE ".bun\install\cache"
        }
    }
} finally {
    Pop-Location
}
if ($cachePath) { $cachePath = ([string]$cachePath).Trim() }

if ($cachePath) {
    Write-DevKitInfo "Cache Path: $cachePath"
} else {
    Write-DevKitInfo "Cache path could not be determined for $($manager.Command)."
}
Write-Host ""

if ($cachePath -and (Test-Path -LiteralPath $cachePath)) {
    # A pnpm store can hold 100k+ files - measure with robocopy in list-only
    # mode first (~5x faster than a Get-ChildItem walk, byte-identical,
    # long-path safe; the same fast path Find-StaleNodeModules.ps1 uses).
    # robocopy's summary is localized, so the Bytes row is parsed by shape;
    # on any failure fall back to the GCI walk, flagged as an estimate.
    $size = $null
    try {
        $rc = & robocopy "$cachePath" "$cachePath.devkit-null" /L /E /BYTES /NFL /NDL /NJH /XJ /R:0 /W:0 2>$null
        $bytesLine = $rc | Select-String -Pattern 'Bytes\s*:' | Select-Object -First 1
        if ($bytesLine -and ($bytesLine.Line -match 'Bytes\s*:\s*([\d\.,]+)')) {
            $size = [double]($Matches[1] -replace '\D', '')
        }
    } catch { }
    $sizeNote = ""
    if ($null -eq $size) {
        $sizeErrors = $null
        $size = (Get-ChildItem -LiteralPath $cachePath -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable sizeErrors |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $size) { $size = 0 }
        if ($sizeErrors -and $sizeErrors.Count -gt 0) { $sizeNote = " (approximate)" }
    }
    $sizeMB = [math]::Round($size / 1MB, 2)
    Write-DevKitInfo "Cache Size: $sizeMB MB$sizeNote"
} elseif ($cachePath) {
    Write-DevKitInfo "That folder does not exist yet - nothing has been cached."
} else {
    Write-DevKitInfo "$($manager.Command) did not report a cache location DevKit can measure."
}

Write-Host ""
