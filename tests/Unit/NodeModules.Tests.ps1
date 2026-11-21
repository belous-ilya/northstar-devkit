#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for node_modules removal and the lock-file safety net in
    tools/lib/DevKit-Common.ps1.
.DESCRIPTION
    Covers Remove-DevKitNodeModulesWithStatus (the three outcomes the old
    boolean could not tell apart, plus the link case),
    Get-DevKitReinstallBlocker, and the set-aside / restore / clean-up trio
    for lock files.

    Everything is created and deleted under TestDrive. The "locked" case
    holds one file open itself; no real project, package manager or process
    is touched.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\NodeModules.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why this load-once flag gets
    # reset when several test files share one Pester process.
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')

    function New-TestProject {
        $dir = Join-Path $TestDrive "proj-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }
}

Describe "Remove-DevKitNodeModulesWithStatus" {

    It "says Absent when there is no node_modules" {
        Remove-DevKitNodeModulesWithStatus -Path (New-TestProject) | Should -Be 'Absent'
    }

    It "says Removed, and the folder is gone" {
        $proj = New-TestProject
        New-Item -ItemType Directory -Path (Join-Path $proj 'node_modules\pkg\lib') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $proj 'node_modules\pkg\lib\index.js') -Value 'x'
        Remove-DevKitNodeModulesWithStatus -Path $proj | Should -Be 'Removed'
        Test-Path -LiteralPath (Join-Path $proj 'node_modules') | Should -BeFalse
    }

    It "says Failed - not Absent - when a file in it is locked" {
        # The case the old boolean reported as "skip": a dev server or an
        # editor still has a file open, so the folder cannot be removed.
        $proj = New-TestProject
        New-Item -ItemType Directory -Path (Join-Path $proj 'node_modules\pkg') -Force | Out-Null
        $held = Join-Path $proj 'node_modules\pkg\held.node'
        Set-Content -LiteralPath $held -Value 'x'
        $lock = [System.IO.File]::Open($held, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            $status = $null
            try { $status = Remove-DevKitNodeModulesWithStatus -Path $proj } catch { $status = 'Failed' }
            $status | Should -Be 'Failed'
            Test-Path -LiteralPath $held | Should -BeTrue
            # And the yes/no wrapper keeps its old meaning: not removed.
            $wrapped = $true
            try { $wrapped = Remove-DevKitNodeModules -Path $proj } catch { $wrapped = $false }
            $wrapped | Should -BeFalse
        } finally {
            $lock.Dispose()
        }
    }

    It "removes only the link when node_modules is a junction, leaving the real folder alone" {
        $proj = New-TestProject
        $shared = Join-Path $TestDrive "shared-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $shared 'pkg') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $shared 'pkg\index.js') -Value 'shared'
        New-Item -ItemType Junction -Path (Join-Path $proj 'node_modules') -Target $shared | Out-Null

        Remove-DevKitNodeModulesWithStatus -Path $proj | Should -Be 'Removed'

        Test-Path -LiteralPath (Join-Path $proj 'node_modules') | Should -BeFalse
        # Mirroring an empty folder through the link would have emptied this.
        Test-Path -LiteralPath (Join-Path $shared 'pkg\index.js') | Should -BeTrue
    }
}

Describe "Get-DevKitReinstallBlocker" {

    It "blocks when there is no package.json" {
        $proj = New-TestProject
        Mock Test-DevKitCommand { $true }
        Get-DevKitReinstallBlocker -Path $proj -Manager @{ Command = 'npm' } | Should -Match 'no package\.json'
    }

    It "blocks when the package manager is not installed" {
        $proj = New-TestProject
        Set-Content -LiteralPath (Join-Path $proj 'package.json') -Value '{}'
        Mock Test-DevKitCommand { $false }
        Get-DevKitReinstallBlocker -Path $proj -Manager @{ Command = 'pnpm' } | Should -Match 'pnpm is not installed'
    }

    It "lets a reinstall start when both are there" {
        $proj = New-TestProject
        Set-Content -LiteralPath (Join-Path $proj 'package.json') -Value '{}'
        Mock Test-DevKitCommand { $true }
        Get-DevKitReinstallBlocker -Path $proj -Manager @{ Command = 'npm' } | Should -BeNullOrEmpty
    }
}

Describe "lock files set aside, restored, cleaned up" {

    BeforeEach {
        $script:Proj = New-TestProject
        Set-Content -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml') -Value 'original-lock'
    }

    It "sets the lock file aside instead of deleting it" {
        $moved = Move-DevKitLockFilesAside -Path $script:Proj
        $moved.Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml.devkit-bak') -Raw | Should -Match 'original-lock'
    }

    It "returns an empty array, not null, when there is nothing to set aside" {
        $moved = Move-DevKitLockFilesAside -Path (New-TestProject)
        $moved.GetType().IsArray | Should -BeTrue
        $moved.Count | Should -Be 0
    }

    It "puts the original back after a failed install, over a half-written new one" {
        $moved = Move-DevKitLockFilesAside -Path $script:Proj
        Set-Content -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml') -Value 'half-written'
        Restore-DevKitLockFiles -Moved $moved
        Get-Content -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml') -Raw | Should -Match 'original-lock'
        Test-Path -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml.devkit-bak') | Should -BeFalse
    }

    It "deletes the backup after a successful install and keeps the new lock file" {
        $moved = Move-DevKitLockFilesAside -Path $script:Proj
        Set-Content -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml') -Value 'fresh-lock'
        Remove-DevKitLockFileBackups -Moved $moved
        Test-Path -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml.devkit-bak') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml') -Raw | Should -Match 'fresh-lock'
    }

    It "replaces a stale backup left by an earlier interrupted run" {
        Set-Content -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml.devkit-bak') -Value 'stale-backup'
        [void](Move-DevKitLockFilesAside -Path $script:Proj)
        Get-Content -LiteralPath (Join-Path $script:Proj 'pnpm-lock.yaml.devkit-bak') -Raw | Should -Match 'original-lock'
    }
}

Describe "the reinstall tools use the safety net" {

    It "<tool> checks it can reinstall, and reports a locked node_modules, before touching lock files" -ForEach @(
        @{ tool = 'tools\node\Nuke-And-Reinstall.ps1' }
        @{ tool = 'tools\nextjs\Next-FullClean.ps1' }
    ) {
        $path = Join-Path $script:RepoRoot $tool
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $offsetOf = {
            param($Name)
            @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true) |
                    ForEach-Object { $_.Extent.StartOffset } | Sort-Object)[0]
        }
        $preflight = & $offsetOf 'Get-DevKitReinstallBlocker'
        $removal = & $offsetOf 'Remove-DevKitNodeModulesWithStatus'
        $aside = & $offsetOf 'Move-DevKitLockFilesAside'
        $restore = & $offsetOf 'Restore-DevKitLockFiles'
        $preflight | Should -Not -BeNullOrEmpty
        $restore | Should -Not -BeNullOrEmpty
        $preflight | Should -BeLessThan $removal
        $removal | Should -BeLessThan $aside
        # Lock files are never deleted outright any more.
        $ast.Extent.Text | Should -Not -Match 'Remove-Item -Path \$_ -Force'
    }
}
