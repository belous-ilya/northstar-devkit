#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests that project folders are taken literally, whatever
    characters are in their names.
.DESCRIPTION
    PowerShell reads the path of Test-Path, Get-ChildItem, Push-Location and
    the like as a wildcard PATTERN unless -LiteralPath is used. Square
    brackets are pattern characters, so a project in a folder called
    `my-app [v2]` "did not exist": every project tool refused it with "Path
    not found", and a Next.js route folder such as `[slug]` was silently
    skipped when sizes were added up.

    Two halves: the shared helpers are RUN against such a folder, and every
    tool script is READ (never executed) to check that no file cmdlet is
    handed a path any other way.
.EXAMPLE
    Invoke-Pester -Path .\tests\Unit\LiteralPaths.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    # See Get-DevKitPackageManager.Tests.ps1 for why this load-once flag gets
    # reset when several test files share one Pester process.
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')

    # A project whose folder name is a valid wildcard pattern that does NOT
    # match itself: "[v2]" means "one character, v or 2".
    $script:Project = Join-Path $TestDrive 'my-app [v2]'
    $null = New-Item -ItemType Directory -Path $script:Project
    [System.IO.File]::WriteAllText((Join-Path $script:Project 'package.json'), '{ "name": "my-app", "scripts": { "dev": "vite" } }')
    [System.IO.File]::WriteAllText((Join-Path $script:Project 'pnpm-lock.yaml'), 'lockfileVersion: 9')
    [System.IO.File]::WriteAllText((Join-Path $script:Project 'vite.config.ts'), 'export default {}')
    $null = New-Item -ItemType Directory -Path (Join-Path $script:Project '.git')
}

Describe "shared helpers accept a project folder with brackets in its name" {

    It "the folder really is one a wildcard read cannot find (so these tests mean something)" {
        Test-Path $script:Project | Should -BeFalse
        Test-Path -LiteralPath $script:Project | Should -BeTrue
    }

    It "Resolve-DevKitDirectory returns it instead of 'Path not found'" {
        Resolve-DevKitDirectory -Path $script:Project | Should -Be $script:Project
    }

    It "Resolve-DevKitDirectory still refuses a folder that does not exist, and a file" {
        { Resolve-DevKitDirectory -Path (Join-Path $TestDrive 'no such [folder]') } | Should -Throw '*Path not found*'
        { Resolve-DevKitDirectory -Path (Join-Path $script:Project 'package.json') } | Should -Throw '*not a directory*'
    }

    It "Invoke-DevKitInDirectory runs the block inside it and comes back" {
        $before = (Get-Location).Path
        $inside = Invoke-DevKitInDirectory -Path $script:Project -ScriptBlock { (Get-Location).Path }
        $inside | Should -Be $script:Project
        (Get-Location).Path | Should -Be $before
    }

    It "Get-DevKitPackageManager finds its lock file" {
        (Get-DevKitPackageManager -Path $script:Project).Command | Should -Be 'pnpm'
    }

    It "Get-DevKitProjectTags sees what is in it" {
        $tags = Get-DevKitProjectTags -Path $script:Project
        $tags | Should -Contain 'node'
        $tags | Should -Contain 'git'
        $tags | Should -Contain 'vite'
    }
}

Describe "tool scripts hand file cmdlets their paths literally" {

    BeforeDiscovery {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ToolScripts = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tools') -Recurse -Filter '*.ps1' |
                Where-Object { $_.FullName -notmatch '\\tools\\(system|wifi)\\' -and $_.Name -notin 'DevKit-UI.ps1', 'DevKit-WiFi.ps1', 'DevKit-McpList.ps1' } |
                ForEach-Object { @{ Name = $_.FullName.Substring($repoRoot.Length + 1); FullName = $_.FullName } })
    }

    BeforeAll {
        # Cmdlets that read their path as a pattern unless told otherwise.
        $script:PathCmdlets = @('Test-Path', 'Get-ChildItem', 'Get-Item', 'Get-Content', 'Remove-Item', 'Push-Location',
            'Set-Location', 'Resolve-Path', 'Move-Item', 'Copy-Item', 'Set-Content')

        function Get-PatternPathCalls {
            param([string]$FullName)
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0
            $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($call in $calls) {
                $name = $call.GetCommandName()
                if ($script:PathCmdlets -notcontains $name) { continue }
                $elements = @($call.CommandElements | Select-Object -Skip 1)
                $parameters = @($elements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] } | ForEach-Object ParameterName)
                if ($parameters -contains 'LiteralPath') { continue }
                # Fed from the pipeline (file objects bind by their literal
                # path), so there is no path argument to get wrong.
                $positional = @($elements | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
                if ($positional.Count -eq 0 -and $parameters -notcontains 'Path') { continue }
                # -Exclude is ignored together with -LiteralPath on Windows
                # PowerShell 5.1, so the one scan that needs it keeps -Path.
                if ($name -eq 'Get-ChildItem' -and $parameters -contains 'Exclude') { continue }
                # A relative name written out in the script has no brackets
                # in it and cannot be anything but itself.
                $pathArgument = $positional | Select-Object -First 1
                if ($pathArgument -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $pathArgument.Value -notmatch '[\[\]\*\?]') { continue }
                '{0}: {1}' -f $call.Extent.StartLineNumber, $call.Extent.Text.Split("`n")[0].Trim()
            }
        }
    }

    It "the check itself catches a pattern read, and passes the forms that are safe" {
        $sample = Join-Path $TestDrive 'sample.ps1'
        Set-Content -LiteralPath $sample -Value @(
            'if (Test-Path $projectPath) { }',                          # caught
            'Get-ChildItem -Path $projectPath -Recurse',                # caught
            'Push-Location (Join-Path $root "app")',                    # caught
            'Remove-Item "$projectPath\dist" -Recurse',                 # caught
            'if (Test-Path -LiteralPath $projectPath) { }',
            'Get-ChildItem -LiteralPath $projectPath | Remove-Item -Force',
            'if (Test-Path "package.json") { }',
            'Get-ChildItem -Path $root -Recurse -Exclude $skip'
        )
        $offenders = @(Get-PatternPathCalls -FullName $sample)
        $offenders.Count | Should -Be 4
        ($offenders -join "`n") | Should -Match '1: if \(Test-Path|1: Test-Path \$projectPath'
    }

    It "<Name>" -ForEach $script:ToolScripts {
        $offenders = @(Get-PatternPathCalls -FullName $FullName)
        $offenders | Should -BeNullOrEmpty -Because 'a path that is not -LiteralPath is read as a wildcard pattern, and a folder with [brackets] in its name then cannot be found'
    }
}
