#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests that hold every tools/*/_module.psd1 to the script it runs.
.DESCRIPTION
    A manifest is the only thing that tells the app and the CLI how to call
    a tool: which script, which switches are fixed (StaticArgs), which the
    user is asked for (Prompts), and whether the app must confirm first
    (caution). Nothing generates one side from the other, and a manifest
    naming a parameter the script does not declare is a hard binding error
    on every run - so this reads both sides and compares them.

    Read-only: scripts are PARSED, never executed.
.NOTES
    Pester 5 syntax (dashed `Should -Be`).
    Run with:
        Invoke-Pester -Path .\tests\Unit\Manifests.Tests.ps1
#>

BeforeDiscovery {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ManifestCases = @(
        Get-ChildItem -Path (Join-Path $repoRoot 'tools') -Filter '_module.psd1' -Recurse | ForEach-Object {
            $folder = Split-Path -Leaf $_.DirectoryName
            $data = Import-PowerShellDataFile -Path $_.FullName
            foreach ($item in $data.Items) {
                @{ folder = $folder; label = [string]$item.Label; item = $item; dir = $_.DirectoryName }
            }
        }
    )
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $global:DevKitCommonLoaded = $false
    . (Join-Path $script:RepoRoot 'tools\lib\DevKit-Common.ps1')
    . (Join-Path $script:RepoRoot 'core\DevKit-GuiCore.ps1')
    $global:DevKitRpcMethodsLoaded = $false
    . (Join-Path $script:RepoRoot 'core\RpcMethods.ps1')

    function Get-ToolParameters {
        param([string]$Dir, [string]$Script)
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Dir $Script), [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $map = @{}
        foreach ($p in @($ast.ParamBlock.Parameters)) { $map[$p.Name.VariablePath.UserPath] = $p.StaticType }
        # A script without [CmdletBinding()] absorbs undeclared arguments
        # (WiFi-FastMode.ps1 relies on that for -Fast).
        $binding = @($ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }).Count -gt 0
        return @{ Types = $map; StrictBinding = $binding }
    }
}

Describe "manifest <folder>: <label>" -ForEach $script:ManifestCases {

    BeforeAll {
        $script:Tool = Get-ToolParameters -Dir $dir -Script $item.Script
    }

    It "names a script that exists, with a .bat launcher beside it" {
        Test-Path -LiteralPath (Join-Path $dir $item.Script) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir ([System.IO.Path]::ChangeExtension($item.Script, '.bat'))) | Should -BeTrue
    }

    It "only fixes arguments the script declares" {
        if (-not $item.StaticArgs) { return }
        foreach ($key in $item.StaticArgs.Keys) {
            if (-not $script:Tool.StrictBinding) { continue }
            $script:Tool.Types.Keys | Should -Contain $key
        }
    }

    It "only asks for arguments the script declares, with a matching type" {
        foreach ($prompt in @($item.Prompts)) {
            if (-not $prompt) { continue }
            $prompt.Type | Should -BeIn @('Int', 'String', 'YesNo')
            $script:Tool.Types.Keys | Should -Contain $prompt.Name
            $declared = $script:Tool.Types[$prompt.Name]
            switch ($prompt.Type) {
                'YesNo' { $declared | Should -Be ([switch]) -Because "$($prompt.Name) is asked as yes/no" }
                'Int' { $declared | Should -Be ([int]) -Because "$($prompt.Name) is asked as a number" }
                'String' { $declared | Should -Be ([string]) -Because "$($prompt.Name) is asked as text" }
            }
        }
    }

    It "takes a project path when it requires a project" {
        if (-not $item.RequiresProject) { return }
        $name = if ($item.ProjectArgName) { [string]$item.ProjectArgName } else { 'Path' }
        $script:Tool.Types.Keys | Should -Contain $name
    }

    It "declares -Force when the app is going to confirm and pass it" {
        $caution = ([string]$item.Help -match 'Safety note:')
        if ($item.Contains('Caution')) { $caution = [bool]$item['Caution'] }
        if (-not $caution) { return }
        # Without -Force a confirmed run has no way to skip the tool's own
        # prompt, which cannot be answered with stdin closed. A caution tool
        # that has no prompt of its own (it never asks) is the one exception,
        # and says so in its Help.
        if ([string]$item.Help -match 'no confirmation prompt') { return }
        $script:Tool.Types.Keys | Should -Contain 'Force'
    }
}

Describe "the caution flag in the catalog payload" {

    BeforeAll {
        $script:Payload = Get-DevKitCatalogPayload -RootPath $script:RepoRoot
        $script:AllItems = @($script:Payload.modules | ForEach-Object { $folder = $_.folder; $_.items | ForEach-Object { [pscustomobject]@{ Folder = $folder; Item = $_ } } })
    }

    It "comes from the Help's Safety note by default" {
        ($script:AllItems | Where-Object { $_.Item.script -eq 'Kill-AllNode.ps1' }).Item.caution | Should -BeTrue
        ($script:AllItems | Where-Object { $_.Item.script -eq 'Scan-Ports.ps1' }).Item.caution | Should -BeFalse
    }

    It "lets a manifest override the text match" {
        # Run Package Script's Help has a Safety note (it runs YOUR script),
        # but it is not a destructive DevKit action and must not put a
        # "cannot be undone" dialog in front of every `npm run dev`.
        $run = ($script:AllItems | Where-Object { $_.Item.script -eq 'Start-PackageScript.ps1' }).Item
        $run.help | Should -Match 'Safety note:'
        $run.caution | Should -BeFalse
    }

    It "keeps Docker volumes unless the item is the one that says otherwise" {
        $nukes = @($script:AllItems | Where-Object { $_.Item.script -eq 'Docker-Nuke.ps1' } | ForEach-Object { $_.Item })
        $nukes.Count | Should -Be 2
        $keeping = @($nukes | Where-Object { $_.staticArgs -and $_.staticArgs['KeepVolumes'] })
        $keeping.Count | Should -Be 1
        $removing = @($nukes | Where-Object { -not ($_.staticArgs -and $_.staticArgs['KeepVolumes']) })
        $removing[0].label | Should -Match 'Including Volumes'
        foreach ($nuke in $nukes) {
            $nuke.caution | Should -BeTrue
            @($nuke.prompts | Where-Object { $_.Name -eq 'DryRun' }).Count | Should -Be 1
        }
    }
}
