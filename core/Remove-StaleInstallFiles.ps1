#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Removes files a previous DevKit version installed and this one no longer
    ships. Run by the installer after it has written the new files.
.DESCRIPTION
    The installer only adds and overwrites: a script that a release deletes
    stays in the install folder for good. For DevKit that is not cosmetic -
    the catalog is built from whatever tools\*\_module.psd1 manifests are on
    disk, so a tool removed from the product kept being listed, and kept
    being runnable, on every install that updated instead of installing
    fresh.

    This runs from the installer's POSTINSTALL hook
    (app/src-tauri/windows/hooks.nsh), i.e. AFTER the new files are in place
    and after the installer has closed a running app. It deletes, inside
    <InstallRoot>\core and <InstallRoot>\tools only, every file that is not
    named in core\ShippedFiles.txt, then removes the folders that emptied.

    It is built to fail towards doing nothing:
      - no list, an implausibly short list, or a list that does not name the
        files that must be there  -> nothing is deleted;
      - the folder is not recognizably a DevKit install -> nothing is deleted;
      - a file that cannot be deleted is skipped and reported, never retried
        harder;
      - links (junctions, symlinks) are neither followed nor removed.
    The worst outcome is that stale files stay - which is what happened on
    every update before this script existed.

    Compatible with Windows PowerShell 5.1: the installer starts it with
    powershell.exe, which every supported Windows has.
.PARAMETER InstallRoot
    The folder DevKit is installed in (the one holding core\ and tools\).
.PARAMETER DryRun
    List what would be removed without removing anything.
.EXAMPLE
    .\Remove-StaleInstallFiles.ps1 -InstallRoot "C:\Users\me\AppData\Local\DevKit" -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# The two folders the installer fills from the repository, and one file in
# each that nothing but DevKit ships. $InstallRoot is whatever folder the
# user chose: an unrelated 'core' or 'tools' directory there must never be
# cleaned on the strength of its name.
$script:ManagedFolders = @(
    @{ Name = 'core'; Marker = 'core\DevKit.Core.psm1' }
    @{ Name = 'tools'; Marker = 'tools\lib\DevKit-Common.ps1' }
)
$script:ListRelativePath = 'core\ShippedFiles.txt'
# A real list holds about eighty entries. Anything much shorter is a
# truncated or wrong file, and acting on it would delete the product.
$script:MinimumListEntries = 40

function ConvertTo-DevKitInstallKey {
    # One spelling per path: backslashes, no leading separator, lower case.
    param([string]$RelativePath)
    return ($RelativePath -replace '/', '\').Trim().TrimStart('\').ToLowerInvariant()
}

function Read-DevKitShippedFileList {
    <#
    .SYNOPSIS
        The shipped-file list as a set of normalized relative paths, or $null
        when the list is missing, too short, or does not name the marker
        files and itself (all of which a real list always does).
    #>
    param([Parameter(Mandatory = $true)][string]$Root)

    $listPath = Join-Path $Root $script:ListRelativePath
    if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) { return $null }
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in [System.IO.File]::ReadAllLines($listPath)) {
        $entry = $line.Trim()
        if (-not $entry -or $entry.StartsWith('#')) { continue }
        [void]$set.Add((ConvertTo-DevKitInstallKey $entry))
    }
    if ($set.Count -lt $script:MinimumListEntries) { return $null }
    if (-not $set.Contains((ConvertTo-DevKitInstallKey $script:ListRelativePath))) { return $null }
    foreach ($folder in $script:ManagedFolders) {
        if (-not $set.Contains((ConvertTo-DevKitInstallKey $folder.Marker))) { return $null }
    }
    return , $set
}

function Get-DevKitInstallTreeFiles {
    <#
    .SYNOPSIS
        Every file below $Folder as a full path, without entering a link.
        (Get-ChildItem -Recurse follows junctions on Windows PowerShell 5.1,
        which could walk - and then delete - outside the install folder.)
    #>
    param([Parameter(Mandatory = $true)][string]$Folder)

    $files = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Folder)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $entries = @()
        try { $entries = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop) } catch { continue }
        foreach ($entry in $entries) {
            $isLink = [bool]($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            if ($isLink) { continue }
            if ($entry.PSIsContainer) { $pending.Push($entry.FullName) } else { $files.Add($entry.FullName) }
        }
    }
    return , $files
}

function Get-DevKitStaleInstallFiles {
    <#
    .SYNOPSIS
        Full paths of the files under the managed folders of $Root that the
        shipped-file list does not name. Empty when anything about the
        folder or the list is not as expected - see the script's description.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)

    $stale = New-Object 'System.Collections.Generic.List[string]'
    $shipped = Read-DevKitShippedFileList -Root $Root
    if ($null -eq $shipped) { return , $stale }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    foreach ($folder in $script:ManagedFolders) {
        if (-not (Test-Path -LiteralPath (Join-Path $rootFull $folder.Marker) -PathType Leaf)) { continue }
        $folderPath = Join-Path $rootFull $folder.Name
        foreach ($file in (Get-DevKitInstallTreeFiles -Folder $folderPath)) {
            if (-not $file.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $relative = $file.Substring($rootFull.Length + 1)
            if (-not $shipped.Contains((ConvertTo-DevKitInstallKey $relative))) { $stale.Add($file) }
        }
    }
    return , $stale
}

function Remove-DevKitEmptyInstallFolders {
    # Deepest first, and only folders that are empty: a folder that still
    # holds a shipped file (or anything undeletable) stays.
    param([Parameter(Mandatory = $true)][string]$Folder)

    $all = New-Object 'System.Collections.Generic.List[string]'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Folder)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $children = @()
        try { $children = @(Get-ChildItem -LiteralPath $current -Force -Directory -ErrorAction Stop) } catch { continue }
        foreach ($child in $children) {
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $all.Add($child.FullName)
            $pending.Push($child.FullName)
        }
    }
    $removed = 0
    foreach ($dir in ($all | Sort-Object { $_.Length } -Descending)) {
        try {
            if (@(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop).Count -eq 0) {
                [System.IO.Directory]::Delete($dir, $false)
                $removed++
            }
        } catch { }
    }
    return $removed
}

function Invoke-DevKitStaleInstallCleanup {
    <#
    .OUTPUTS
        @{ Stale = <count found>; Removed; Failed; FoldersRemoved; Files = <the stale paths> }
    #>
    param([Parameter(Mandatory = $true)][string]$Root, [switch]$DryRun)

    $result = @{ Stale = 0; Removed = 0; Failed = 0; FoldersRemoved = 0; Files = @() }
    $stale = Get-DevKitStaleInstallFiles -Root $Root
    $result.Stale = $stale.Count
    $result.Files = @($stale)
    if ($DryRun -or $stale.Count -eq 0) { return $result }

    foreach ($file in $stale) {
        try {
            # A read-only stale file is still stale.
            $info = New-Object System.IO.FileInfo($file)
            if ($info.IsReadOnly) { $info.IsReadOnly = $false }
            [System.IO.File]::Delete($file)
            $result.Removed++
        } catch {
            $result.Failed++
        }
    }
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    foreach ($folder in $script:ManagedFolders) {
        $folderPath = Join-Path $rootFull $folder.Name
        if (Test-Path -LiteralPath $folderPath -PathType Container) {
            $result.FoldersRemoved += (Remove-DevKitEmptyInstallFolders -Folder $folderPath)
        }
    }
    return $result
}

# Dot-sourced (the unit tests load the functions this way): define, don't run.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    $outcome = Invoke-DevKitStaleInstallCleanup -Root $InstallRoot -DryRun:$DryRun
    if ($DryRun) {
        Write-Output "DevKit stale-file check: $($outcome.Stale) file(s) would be removed."
        $outcome.Files | ForEach-Object { Write-Output "  $_" }
    } else {
        Write-Output "DevKit stale-file cleanup: removed $($outcome.Removed) of $($outcome.Stale) file(s), $($outcome.FoldersRemoved) empty folder(s); $($outcome.Failed) could not be removed."
    }
    exit 0
} catch {
    # Never fail the install over leftovers.
    Write-Output "DevKit stale-file cleanup skipped: $($_.Exception.Message)"
    exit 0
}
