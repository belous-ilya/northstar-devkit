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
    and after the installer has closed a running app.

    IT DELETES ONLY PATHS DEVKIT ITSELF ONCE SHIPPED. core\RemovedFiles.txt
    names every file an earlier release installed under core\ or tools\ that
    this one does not; those, and nothing else, are removed, followed by the
    folders they emptied. It never walks a folder looking for "anything not
    on the shipped list", and that is deliberate: the install folder is
    whatever the user picked, and a tools\ or core\ directory there may hold
    files that were never DevKit's. (An earlier draft did walk, guarded by
    "does this look like a DevKit folder" - a check that ran after the
    installer had just written the very files it looked for, so it was
    always true.) A file nobody shipped is not this script's to judge.

    It is built to fail towards doing nothing:
      - no shipped list, an implausibly short one, or one that does not name
        the files every real list names -> nothing is deleted;
      - an entry that is also on the shipped list, that points outside
        core\ or tools\, or that contains '..' -> skipped;
      - a path that passes through a link (junction, symlink) -> skipped;
      - a file that cannot be deleted is counted and left.
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

# The two folders the installer fills from the repository. Nothing outside
# them is ever touched, whatever a list says.
$script:ManagedFolders = @('core', 'tools')
$script:ShippedListPath = 'core\ShippedFiles.txt'
$script:RemovedListPath = 'core\RemovedFiles.txt'
# Files every real shipped list names. A list without them is not ours.
$script:RequiredShippedEntries = @('core\ShippedFiles.txt', 'core\DevKit.Core.psm1', 'tools\lib\DevKit-Common.ps1')
# A real shipped list holds about eighty entries. Anything much shorter is a
# truncated or wrong file.
$script:MinimumShippedEntries = 40

function ConvertTo-DevKitInstallKey {
    # One spelling per path: backslashes, no leading separator, lower case.
    param([string]$RelativePath)
    return ($RelativePath -replace '/', '\').Trim().TrimStart('\').ToLowerInvariant()
}

function Read-DevKitInstallList {
    # Entries of a list file (blank lines and # comments dropped), or $null
    # when the file is missing or unreadable.
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $entries = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            $entry = $line.Trim()
            if (-not $entry -or $entry.StartsWith('#')) { continue }
            $entries.Add($entry)
        }
    } catch { return $null }
    return , $entries
}

function Read-DevKitShippedFileSet {
    <#
    .SYNOPSIS
        The shipped-file list as a set of normalized relative paths, or $null
        when it is missing, too short, or does not name the files every real
        list names.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)

    $entries = Read-DevKitInstallList -Path (Join-Path $Root $script:ShippedListPath)
    if ($null -eq $entries) { return $null }
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($entry in $entries) { [void]$set.Add((ConvertTo-DevKitInstallKey $entry)) }
    if ($set.Count -lt $script:MinimumShippedEntries) { return $null }
    foreach ($required in $script:RequiredShippedEntries) {
        if (-not $set.Contains((ConvertTo-DevKitInstallKey $required))) { return $null }
    }
    return , $set
}

function Test-DevKitManagedRelativePath {
    <#
    .SYNOPSIS
        Pure: is this list entry a plain relative path inside core\ or
        tools\? No drive, no leading separator, no '.' or '..' segment -
        and no spelling that Windows would quietly turn into a DIFFERENT
        name than the one written.
    .DESCRIPTION
        The "never delete a shipped file" rule compares spellings, so every
        entry has to be the one canonical spelling of its file. Windows
        strips a trailing dot or space from a path segment, and resolves
        8.3 short names: 'core\DevKit.Core.psm1.' and 'core\DEVKIT~1.PSM'
        are the shipped module under names the shipped list does not hold.
        A real DevKit path never ends a segment in '.' or ' ' and never
        contains '~' or a wildcard, so those are simply refused.
    #>
    param([string]$RelativePath)

    $key = ConvertTo-DevKitInstallKey $RelativePath
    if (-not $key -or $key.Contains(':')) { return $false }
    if ($key.IndexOfAny([char[]]'~*?<>|"') -ge 0) { return $false }
    $segments = $key.Split('\')
    if ($segments.Length -lt 2) { return $false }
    if ($script:ManagedFolders -notcontains $segments[0]) { return $false }
    foreach ($segment in $segments) {
        if (-not $segment -or $segment -eq '.' -or $segment -eq '..') { return $false }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment.StartsWith(' ')) { return $false }
    }
    return $true
}

function Test-DevKitPathCrossesLink {
    <#
    .SYNOPSIS
        Does any existing component of $RelativePath below $Root - a folder on
        the way, or the file itself - turn out to be a link (junction,
        symlink)? Such a path leads somewhere this script was never told
        about, so it is left alone.
    #>
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$RelativePath)

    $current = $Root
    foreach ($segment in (ConvertTo-DevKitInstallKey $RelativePath).Split('\')) {
        $current = Join-Path $current $segment
        $item = $null
        try { $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop } catch { return $false }   # not there: nothing to cross
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $true }
    }
    return $false
}

function Get-DevKitStaleInstallFiles {
    <#
    .SYNOPSIS
        Full paths of the files under $Root that an earlier DevKit shipped,
        this one does not, and that are still there. Empty when either list
        is missing or the shipped list is not plausible.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)

    $stale = New-Object 'System.Collections.Generic.List[string]'
    $shipped = Read-DevKitShippedFileSet -Root $Root
    if ($null -eq $shipped) { return , $stale }
    $removed = Read-DevKitInstallList -Path (Join-Path $Root $script:RemovedListPath)
    if ($null -eq $removed) { return , $stale }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($entry in $removed) {
        if (-not (Test-DevKitManagedRelativePath $entry)) { continue }
        $key = ConvertTo-DevKitInstallKey $entry
        if ($shipped.Contains($key)) { continue }          # shipped again: never delete
        if (-not $seen.Add($key)) { continue }
        $full = Join-Path $rootFull $key
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        if (Test-DevKitPathCrossesLink -Root $rootFull -RelativePath $key) { continue }
        $stale.Add($full)
    }
    return , $stale
}

function Remove-DevKitEmptiedInstallFolders {
    <#
    .SYNOPSIS
        Removes the folders the deleted files lived in, deepest first, when
        (and only when) they are now empty. Never core\ or tools\ themselves,
        never a link, never a folder that still holds anything.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$DeletedFiles
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidates = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $DeletedFiles) {
        $dir = Split-Path -Parent $file
        while ($dir -and $dir.Length -gt $rootFull.Length) {
            $relative = $dir.Substring($rootFull.Length + 1)
            # stop at core\ and tools\ themselves: they are never removed
            if ($relative.Split('\').Length -lt 2) { break }
            [void]$candidates.Add($dir)
            $dir = Split-Path -Parent $dir
        }
    }
    $removed = 0
    foreach ($dir in ($candidates | Sort-Object { $_.Length } -Descending)) {
        try {
            $item = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
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

    # One absolute spelling for everything below: the lists are read through
    # PowerShell (its location) and files are deleted through .NET (the
    # process directory), and a relative root would mean two different
    # folders to those two.
    $Root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)

    $result = @{ Stale = 0; Removed = 0; Failed = 0; FoldersRemoved = 0; Files = @() }
    $stale = Get-DevKitStaleInstallFiles -Root $Root
    $result.Stale = $stale.Count
    $result.Files = @($stale)
    if ($DryRun -or $stale.Count -eq 0) { return $result }

    $deleted = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in $stale) {
        try {
            # A read-only stale file is still stale.
            $info = New-Object System.IO.FileInfo($file)
            if ($info.IsReadOnly) { $info.IsReadOnly = $false }
            [System.IO.File]::Delete($file)
            $deleted.Add($file)
            $result.Removed++
        } catch {
            $result.Failed++
        }
    }
    $result.FoldersRemoved = Remove-DevKitEmptiedInstallFolders -Root $Root -DeletedFiles ([string[]]$deleted.ToArray())
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
