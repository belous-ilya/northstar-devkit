#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Writes core/ShippedFiles.txt (every file the installer puts under core\
    and tools\) and core/RemovedFiles.txt (every file an earlier release put
    there that this tree no longer has). Re-run this after adding, renaming
    or deleting any file in either folder.
.DESCRIPTION
    After an update, core/Remove-StaleInstallFiles.ps1 deletes the files
    named in RemovedFiles.txt - that is how a script removed from the
    product also disappears from installs that update. It deletes nothing
    else, so RemovedFiles.txt has to remember every path DevKit ever
    shipped and no longer does.

    It remembers by accumulating: each run compares the ShippedFiles.txt
    that is already committed with the tree, and whatever the old list named
    that is gone is added to RemovedFiles.txt. A path that comes back is
    taken off it again. tests/Unit/ShippedFiles.Tests.ps1 fails when
    ShippedFiles.txt and the tree disagree, which is what forces this script
    to be run - and so the removal to be recorded - whenever a file is
    deleted. Do not hand-edit either list.

    -SeedFromTags additionally adds every core\ and tools\ path found in the
    repository's v* release tags (git required). It was used once, to give
    the list the releases made before the list existed; it is harmless to
    run again.

    Dev-time only, like Export-Catalog.ps1.
.PARAMETER SeedFromTags
    Also record every path that any v* release tag shipped under core\ or
    tools\ and that the tree no longer has.
#>
[CmdletBinding()]
param([switch]$SeedFromTags)

$ErrorActionPreference = 'Stop'

function Get-DevKitRemovedFileList {
    <#
    .SYNOPSIS
        Pure: the new removed-files list. Everything that was already on it,
        plus whatever the previous shipped list named and the new one does
        not, plus any extra historical paths - minus everything shipped now.
        Case-insensitive, de-duplicated, sorted.
    #>
    param(
        [AllowEmptyCollection()][string[]]$PreviousRemoved = @(),
        [AllowEmptyCollection()][string[]]$PreviousShipped = @(),
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$NowShipped,
        [AllowEmptyCollection()][string[]]$Historical = @()
    )

    $now = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $NowShipped) { [void]$now.Add(($path -replace '/', '\').Trim()) }
    $removed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($PreviousRemoved) + @($PreviousShipped) + @($Historical)) {
        $clean = ("$path" -replace '/', '\').Trim()
        if (-not $clean) { continue }
        if ($clean -notmatch '^(core|tools)\\') { continue }
        if ($now.Contains($clean)) { continue }
        [void]$removed.Add($clean)
    }
    return @($removed | Sort-Object { $_.ToLowerInvariant() })
}

function Read-DevKitListFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @([System.IO.File]::ReadAllLines($Path) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

# Dot-sourced (the unit tests load the pure function this way): define, don't run.
if ($MyInvocation.InvocationName -eq '.') { return }

$repoRoot = Split-Path -Parent $PSScriptRoot
$shippedPath = Join-Path $PSScriptRoot 'ShippedFiles.txt'
$removedPath = Join-Path $PSScriptRoot 'RemovedFiles.txt'

$previousShipped = Read-DevKitListFile -Path $shippedPath
$previousRemoved = Read-DevKitListFile -Path $removedPath

$entries = New-Object 'System.Collections.Generic.List[string]'
foreach ($folder in 'core', 'tools') {
    $base = Join-Path $repoRoot $folder
    foreach ($file in (Get-ChildItem -LiteralPath $base -Recurse -File -Force)) {
        $entries.Add($file.FullName.Substring($repoRoot.Length + 1))
    }
}
# Both lists ship too, and the shipped list has to name them (either may not
# exist yet on a first run).
foreach ($self in 'core\ShippedFiles.txt', 'core\RemovedFiles.txt') {
    if (-not ($entries -contains $self)) { $entries.Add($self) }
}
$nowShipped = @($entries | Sort-Object { $_.ToLowerInvariant() } -Unique)

$historical = @()
if ($SeedFromTags) {
    $tags = @(& git -C $repoRoot tag --list 'v*')
    if ($LASTEXITCODE -ne 0 -or $tags.Count -eq 0) { throw 'No v* tags found - -SeedFromTags needs the release tags (a full clone).' }
    foreach ($tag in $tags) {
        $historical += @(& git -C $repoRoot ls-tree -r --name-only $tag -- core tools | ForEach-Object { $_ -replace '/', '\' })
    }
    Write-Host "Read $($tags.Count) release tag(s): $($tags -join ', ')" -ForegroundColor DarkGray
}

$nowRemoved = Get-DevKitRemovedFileList -PreviousRemoved $previousRemoved -PreviousShipped $previousShipped -NowShipped $nowShipped -Historical $historical

$utf8 = New-Object System.Text.UTF8Encoding($false)
$shippedHeader = @(
    '# Every file the installer puts under core\ and tools\. GENERATED by'
    '# core/Export-ShippedFiles.ps1 - do not edit by hand. A test fails when'
    '# this list and the tree disagree.'
)
$removedHeader = @(
    '# Every file an EARLIER DevKit release installed under core\ or tools\ that'
    '# this one no longer ships. GENERATED by core/Export-ShippedFiles.ps1 - do'
    '# not edit by hand. After an update, core/Remove-StaleInstallFiles.ps1'
    '# deletes exactly these files (and the folders they empty), nothing else.'
)
[System.IO.File]::WriteAllLines($shippedPath, [string[]]($shippedHeader + $nowShipped), $utf8)
[System.IO.File]::WriteAllLines($removedPath, [string[]]($removedHeader + $nowRemoved), $utf8)
$added = @($nowRemoved | Where-Object { $previousRemoved -notcontains $_ }).Count
Write-Host "Wrote $shippedPath - $($nowShipped.Count) files." -ForegroundColor Green
Write-Host "Wrote $removedPath - $($nowRemoved.Count) removed paths ($added new)." -ForegroundColor Green
