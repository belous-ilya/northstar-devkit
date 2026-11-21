#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for how DevKit's JSON stores (settings.json, projects.json)
    behave when the file cannot be read - as opposed to when it is corrupt.
.DESCRIPTION
    The two used to be handled as one: any exception while loading sent the
    file to quarantine and reset everything to defaults, and a save that
    could not read the file first wrote back only the caller's (partial)
    object. One transient sharing violation could therefore wipe every
    preference or the whole linked-projects list.

    Reads are faulted through Read-DevKitStoreFile, the seam that exists for
    exactly this; a real file lock would block the write as well and prove
    nothing. Every path is redirected into TestDrive - the real
    %LOCALAPPDATA%\NorthstarDevKit files are never touched.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\StoreFiles.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why this load-once flag gets
    # reset when several test files share one Pester process.
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')
}

Describe "Read-DevKitStoreFile" {

    It "returns null for a missing file" {
        Read-DevKitStoreFile -Path (Join-Path $TestDrive 'nope.json') | Should -BeNullOrEmpty
    }

    It "reads BOM-less UTF-8 exactly" {
        $path = Join-Path $TestDrive 'utf8.json'
        $text = "{ `"name`": `"Jos$([char]0x00E9)`" }"
        [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
        Read-DevKitStoreFile -Path $path | Should -Be $text
    }

    It "throws, after retrying, when the file exists but stays locked" {
        $path = Join-Path $TestDrive 'locked.json'
        Set-Content -LiteralPath $path -Value '{}'
        $lock = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            { Read-DevKitStoreFile -Path $path } | Should -Throw -ExpectedMessage 'Could not read*'
        } finally {
            $lock.Dispose()
        }
    }
}

Describe "settings.json" {

    BeforeEach {
        $script:SettingsPath = Join-Path $TestDrive "settings-$([guid]::NewGuid().ToString('N')).json"
        Mock Get-DevKitSettingsFile { $script:SettingsPath }
        Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 -Value '{ "schemaVersion": 1, "preferences": { "appTheme": "nord", "uiScale": 1.2, "confirmDestructive": false } }'
        $script:Before = [System.IO.File]::ReadAllText($script:SettingsPath)
    }

    It "loads what is on disk, with defaults filled in for missing keys" {
        $s = Get-DevKitSettings
        $s.preferences.appTheme | Should -Be 'nord'
        $s.preferences.uiScale | Should -Be 1.2
        $s.preferences.enableAnimations | Should -BeTrue
    }

    It "does not quarantine a file it merely could not read" {
        Mock Read-DevKitStoreFile { throw 'Could not read: being used by another process' }
        $s = Get-DevKitSettings
        # This call is answered with defaults...
        $s.preferences.appTheme | Should -Be 'northstar'
        # ...and the real file is still there, untouched, with no "corrupt" copy.
        [System.IO.File]::ReadAllText($script:SettingsPath) | Should -Be $script:Before
        @(Get-ChildItem -LiteralPath $TestDrive -Filter ((Split-Path -Leaf $script:SettingsPath) + '.corrupt-*')).Count | Should -Be 0
    }

    It "still quarantines a file that was read and does not parse" {
        Set-Content -LiteralPath $script:SettingsPath -Value '{ not json'
        Mock Write-DevKitError { }
        (Get-DevKitSettings).preferences.appTheme | Should -Be 'northstar'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter ((Split-Path -Leaf $script:SettingsPath) + '.corrupt-*')).Count | Should -Be 1
    }

    It "merges a one-key patch over the file instead of replacing it" {
        Set-DevKitSettings -Settings ([PSCustomObject]@{ preferences = [PSCustomObject]@{ widgetSavedWidth = 412 } })
        $s = Get-DevKitSettings
        $s.preferences.widgetSavedWidth | Should -Be 412
        $s.preferences.appTheme | Should -Be 'nord'
        $s.preferences.confirmDestructive | Should -BeFalse
    }

    It "fails the save, and leaves the file alone, when it cannot read what it would merge over" {
        # The clobber this guards: the app saves a one-key patch; the read
        # of the existing file fails; the patch used to be written as the
        # WHOLE file, reverting theme, hotkey, dock side and everything else.
        Mock Read-DevKitStoreFile { throw 'Could not read: being used by another process' }
        { Set-DevKitSettings -Settings ([PSCustomObject]@{ preferences = [PSCustomObject]@{ widgetSavedWidth = 412 } }) } |
            Should -Throw -ExpectedMessage 'Failed to save settings*'
        [System.IO.File]::ReadAllText($script:SettingsPath) | Should -Be $script:Before
    }

    It "creates the file on a first save" {
        Remove-Item -LiteralPath $script:SettingsPath
        Set-DevKitSettings -Settings ([PSCustomObject]@{ schemaVersion = 1; preferences = [PSCustomObject]@{ appTheme = 'monokai' } })
        (Get-DevKitSettings).preferences.appTheme | Should -Be 'monokai'
    }
}

Describe "projects.json" {

    BeforeEach {
        $script:ProjectsPath = Join-Path $TestDrive "projects-$([guid]::NewGuid().ToString('N')).json"
        Mock Get-DevKitProjectsFile { $script:ProjectsPath }
        Set-Content -LiteralPath $script:ProjectsPath -Encoding UTF8 -Value '{ "schemaVersion": 1, "activeProjectId": "a", "projects": [ { "id": "a", "name": "Alpha", "path": "D:\\A" }, { "id": "b", "name": "Beta", "path": "D:\\B" } ] }'
        $script:Before = [System.IO.File]::ReadAllText($script:ProjectsPath)
    }

    It "loads the registry" {
        $r = Get-DevKitProjectRegistry
        @($r.projects).Count | Should -Be 2
        $r.activeProjectId | Should -Be 'a'
    }

    It "does not quarantine a registry it merely could not read" {
        Mock Read-DevKitStoreFile { throw 'Could not read: being used by another process' }
        @((Get-DevKitProjectRegistry).projects).Count | Should -Be 0
        [System.IO.File]::ReadAllText($script:ProjectsPath) | Should -Be $script:Before
        @(Get-ChildItem -LiteralPath $TestDrive -Filter ((Split-Path -Leaf $script:ProjectsPath) + '.corrupt-*')).Count | Should -Be 0
    }

    It "fails the save, and leaves the registry alone, when it cannot read what is on disk" {
        $mine = Get-DevKitProjectRegistry
        Mock Read-DevKitStoreFile { throw 'Could not read: being used by another process' }
        { Save-DevKitProjectRegistry -Registry $mine } | Should -Throw -ExpectedMessage 'Failed to save project registry*'
        [System.IO.File]::ReadAllText($script:ProjectsPath) | Should -Be $script:Before
    }

    It "keeps every project on disk when a save follows a read that came back empty" {
        # The sequence a transient read failure produces: load (empty,
        # because unreadable), add one project, save. Nothing already linked
        # may be lost to it.
        Mock Read-DevKitStoreFile { throw 'Could not read: being used by another process' }
        $mine = Get-DevKitProjectRegistry
        Should -Invoke Read-DevKitStoreFile -Times 1 -Exactly
        Mock Read-DevKitStoreFile { [System.IO.File]::ReadAllText($Path) }
        $mine.projects = @([PSCustomObject]@{ id = 'c'; name = 'Gamma'; path = 'D:\C' })
        Save-DevKitProjectRegistry -Registry $mine
        $ids = @((Get-DevKitProjectRegistry).projects | ForEach-Object { $_.id }) | Sort-Object
        $ids | Should -Be @('a', 'b', 'c')
    }
}
