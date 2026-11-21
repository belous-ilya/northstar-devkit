#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the update-time cleanup: core/ShippedFiles.txt and
    core/Remove-StaleInstallFiles.ps1.
.DESCRIPTION
    The installer only adds and overwrites, so a script a release deletes
    used to stay in every install that updated - and DevKit builds its
    catalog from the manifests on disk, so the removed tool stayed listed.
    After installing, the installer now runs Remove-StaleInstallFiles.ps1,
    which deletes whatever is under core\ and tools\ and not on the list.

    Two things can go wrong, and both are pinned here: the list drifting
    from the tree (a missing entry gets a SHIPPED file deleted on update),
    and the cleanup deleting anything it should not. Every run in this file
    is against a throwaway folder under TestDrive.
.NOTES
    Pester 5 syntax.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CleanupScript = Join-Path $script:RepoRoot 'core\Remove-StaleInstallFiles.ps1'
    $script:ListPath = Join-Path $script:RepoRoot 'core\ShippedFiles.txt'
    # Dot-sourced: defines the functions, runs nothing.
    . $script:CleanupScript -InstallRoot 'unused'

    function Get-ListEntries {
        return @([System.IO.File]::ReadAllLines($script:ListPath) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }

    # A folder that looks like an installed DevKit: every listed file exists
    # (empty - only names matter), plus the list itself with its real content.
    function New-FakeInstall {
        $root = Join-Path $TestDrive "install-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        foreach ($entry in (Get-ListEntries)) {
            $target = Join-Path $root $entry
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
            [System.IO.File]::WriteAllText($target, '')
        }
        Copy-Item -LiteralPath $script:ListPath -Destination (Join-Path $root 'core\ShippedFiles.txt') -Force
        return $root
    }

    function Add-File([string]$Root, [string]$Relative, [switch]$ReadOnly) {
        $target = Join-Path $Root $Relative
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force)
        [System.IO.File]::WriteAllText($target, 'old')
        if ($ReadOnly) { (Get-Item -LiteralPath $target).IsReadOnly = $true }
        return $target
    }

    function Get-AllFiles([string]$Root) {
        return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Root.Length + 1).ToLowerInvariant() } | Sort-Object)
    }
}

Describe "core/ShippedFiles.txt matches what the installer ships" {

    BeforeAll {
        $script:Listed = @(Get-ListEntries | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
        $script:OnDisk = @(foreach ($folder in 'core', 'tools') {
                Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot $folder) -Recurse -File -Force |
                    ForEach-Object { $_.FullName.Substring($script:RepoRoot.Length + 1).ToLowerInvariant() }
            }) | Sort-Object
    }

    It "names every file under core\ and tools\ (a missing entry would get a shipped file deleted on update)" {
        $missing = @($script:OnDisk | Where-Object { $script:Listed -notcontains $_ })
        $missing | Should -BeNullOrEmpty -Because 'run core/Export-ShippedFiles.ps1 after adding or renaming a file'
    }

    It "names nothing that is not there (an extra entry would let a removed file stay)" {
        $extra = @($script:Listed | Where-Object { $script:OnDisk -notcontains $_ })
        $extra | Should -BeNullOrEmpty -Because 'run core/Export-ShippedFiles.ps1 after deleting or renaming a file'
    }

    It "names itself, the cleanup script and both marker files" {
        foreach ($required in 'core\shippedfiles.txt', 'core\remove-staleinstallfiles.ps1', 'core\devkit.core.psm1', 'tools\lib\devkit-common.ps1') {
            $script:Listed | Should -Contain $required
        }
    }

    It "is long enough to pass the cleanup's own plausibility floor, with room to spare" {
        $script:Listed.Count | Should -BeGreaterThan ($script:MinimumListEntries + 20)
    }
}

Describe "Remove-StaleInstallFiles.ps1" {

    It "removes exactly the files a previous version left behind, and the folders they emptied" {
        $root = New-FakeInstall
        $before = Get-AllFiles $root
        # What 4.7.0 installed and this version no longer ships:
        [void](Add-File $root 'tools\maintenance\_module.psd1')
        [void](Add-File $root 'tools\maintenance\Clear-DiskJunk.ps1')
        [void](Add-File $root 'tools\agents\deep\nested\Old.ps1')
        [void](Add-File $root 'tools\ports\Removed-Tool.ps1')
        [void](Add-File $root 'core\Old-Helper.ps1' -ReadOnly)

        $result = Invoke-DevKitStaleInstallCleanup -Root $root
        $result.Stale | Should -Be 5
        $result.Removed | Should -Be 5
        $result.Failed | Should -Be 0
        (Get-AllFiles $root) | Should -Be $before
        Test-Path -LiteralPath (Join-Path $root 'tools\maintenance') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'tools\agents') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'tools\ports') | Should -BeTrue
    }

    It "is what makes a removed category disappear from the catalog" {
        $root = New-FakeInstall
        [void](Add-File $root 'tools\maintenance\_module.psd1')
        @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Recurse -Filter '_module.psd1').Count | Should -BeGreaterThan 7
        [void](Invoke-DevKitStaleInstallCleanup -Root $root)
        $manifests = @(Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Recurse -Filter '_module.psd1' | ForEach-Object { $_.Directory.Name })
        $manifests | Should -Not -Contain 'maintenance'
        $manifests.Count | Should -Be 7
    }

    It "touches nothing outside core\ and tools\" {
        $root = New-FakeInstall
        $keep1 = Add-File $root 'devkit-app.exe'
        $keep2 = Add-File $root 'notes\tools\mine.ps1'
        $keep3 = Add-File $root 'uninstall.exe'
        [void](Add-File $root 'tools\maintenance\x.ps1')
        [void](Invoke-DevKitStaleInstallCleanup -Root $root)
        foreach ($kept in $keep1, $keep2, $keep3) { Test-Path -LiteralPath $kept | Should -BeTrue }
    }

    It "leaves a clean install exactly as it is" {
        $root = New-FakeInstall
        $before = Get-AllFiles $root
        $result = Invoke-DevKitStaleInstallCleanup -Root $root
        $result.Stale | Should -Be 0
        (Get-AllFiles $root) | Should -Be $before
    }

    It "lists but deletes nothing with -DryRun" {
        $root = New-FakeInstall
        $stale = Add-File $root 'tools\maintenance\x.ps1'
        $result = Invoke-DevKitStaleInstallCleanup -Root $root -DryRun
        $result.Stale | Should -Be 1
        $result.Removed | Should -Be 0
        @($result.Files) | Should -Contain $stale
        Test-Path -LiteralPath $stale | Should -BeTrue
    }

    It "deletes nothing when the list is missing" {
        $root = New-FakeInstall
        $stale = Add-File $root 'tools\maintenance\x.ps1'
        Remove-Item -LiteralPath (Join-Path $root 'core\ShippedFiles.txt')
        (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
        Test-Path -LiteralPath $stale | Should -BeTrue
    }

    It "deletes nothing when the list is implausibly short (truncated) - acting on it would delete the product" {
        $root = New-FakeInstall
        $before = Get-AllFiles $root
        [System.IO.File]::WriteAllLines((Join-Path $root 'core\ShippedFiles.txt'), [string[]]@('core\ShippedFiles.txt', 'core\DevKit.Core.psm1', 'tools\lib\DevKit-Common.ps1'))
        (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
        (Get-AllFiles $root) | Should -Be $before
    }

    It "deletes nothing when the list does not name the files every real list names" {
        $root = New-FakeInstall
        $before = Get-AllFiles $root
        $withoutMarker = @(Get-ListEntries | Where-Object { $_ -ne 'tools\lib\DevKit-Common.ps1' })
        [System.IO.File]::WriteAllLines((Join-Path $root 'core\ShippedFiles.txt'), [string[]]$withoutMarker)
        (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
        (Get-AllFiles $root) | Should -Be $before
    }

    It "leaves a 'tools' folder alone when it is not DevKit's (its marker file is absent)" {
        # The user installed into a folder that already had an unrelated
        # tools\ directory; core\ is DevKit's, tools\ is not.
        $root = New-FakeInstall
        Remove-Item -LiteralPath (Join-Path $root 'tools\lib\DevKit-Common.ps1')
        $theirs = Add-File $root 'tools\their-own-script.ps1'
        $ourStale = Add-File $root 'core\Old-Helper.ps1'
        [void](Invoke-DevKitStaleInstallCleanup -Root $root)
        Test-Path -LiteralPath $theirs | Should -BeTrue
        Test-Path -LiteralPath $ourStale | Should -BeFalse
    }

    It "does not follow a link out of the install folder, and does not remove the link" {
        $root = New-FakeInstall
        $outside = Join-Path $TestDrive "outside-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $precious = Add-File $outside 'precious.txt'
        $link = Join-Path $root 'tools\linked'
        [void](New-Item -ItemType Junction -Path $link -Target $outside)
        try {
            [void](Invoke-DevKitStaleInstallCleanup -Root $root)
            Test-Path -LiteralPath $precious | Should -BeTrue
            Test-Path -LiteralPath $link | Should -BeTrue
        } finally {
            # Unlink before TestDrive cleanup, so nothing is deleted THROUGH it.
            [System.IO.Directory]::Delete($link, $false)
        }
    }

    It "treats paths case-insensitively and accepts either slash in the list" {
        $root = New-FakeInstall
        $entries = @(Get-ListEntries | ForEach-Object { $_.ToUpperInvariant() -replace '\\', '/' })
        [System.IO.File]::WriteAllLines((Join-Path $root 'core\ShippedFiles.txt'), [string[]]$entries)
        $before = Get-AllFiles $root
        (Invoke-DevKitStaleInstallCleanup -Root $root).Stale | Should -Be 0
        (Get-AllFiles $root) | Should -Be $before
    }

    It "runs as the installer runs it - Windows PowerShell 5.1, -File, exit code 0 - and cleans up" {
        $root = New-FakeInstall
        $stale = Add-File $root 'tools\maintenance\_module.psd1'
        $output = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:CleanupScript -InstallRoot $root 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'removed 1 of 1 file'
        Test-Path -LiteralPath $stale | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'core\DevKit.Core.psm1') | Should -BeTrue
    }

    It "exits 0 and says why when pointed at a folder that is not an install" {
        $empty = Join-Path $TestDrive "empty-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        [void](New-Item -ItemType Directory -Path $empty)
        $output = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:CleanupScript -InstallRoot $empty 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'removed 0 of 0'
    }
}

Describe "the installer runs the cleanup after installing" {

    BeforeAll {
        $script:Hooks = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'app\src-tauri\windows\hooks.nsh'))
    }

    It "calls the script from POSTINSTALL, with the install folder" {
        $script:Hooks | Should -Match '!macro NSIS_HOOK_POSTINSTALL'
        $script:Hooks.Contains('-File "$INSTDIR\core\Remove-StaleInstallFiles.ps1" -InstallRoot "$INSTDIR"') | Should -BeTrue
    }

    It "deletes nothing itself before the new files are written" {
        # A delete-first PREINSTALL hook runs before the installer's own
        # running-app check, which the user can cancel - leaving a working
        # app with no scripts.
        $script:Hooks | Should -Not -Match '!macro NSIS_HOOK_PREINSTALL'
        $script:Hooks | Should -Not -Match 'RMDir /r "\$INSTDIR'
    }

    It "keeps the elevation task when the uninstaller runs as part of an update" {
        $guard = $script:Hooks.IndexOf('${If} $UpdateMode <> 1')
        $delete = $script:Hooks.IndexOf('schtasks /delete /tn "NorthstarDevKit-Admin"')
        $guard | Should -BeGreaterThan -1
        $delete | Should -BeGreaterThan $guard
    }
}
