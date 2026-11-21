#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pester tests for the DevKit GUI pure-logic core (core/DevKit-GuiCore.ps1)
.DESCRIPTION
    Covers the GUI's argument resolution (which the CLI's build_arguments
    must match exactly), the shell-quoting helpers, the terminal launch
    command builder, and catalog loading against the real manifests - the
    last of which doubles as a manifest/script integrity check for the repo.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:CommonModule = Join-Path (Join-Path $script:RepoRoot "tools\lib") "DevKit-Common.ps1"
    # See Get-DevKitPackageManager.Tests.ps1 for why this flag reset matters
    # when several test files run in one Pester process.
    $global:DevKitCommonLoaded = $false
    . $script:CommonModule
    . (Join-Path (Join-Path $script:RepoRoot "core") "DevKit-GuiCore.ps1")
}

Describe "ConvertTo-DevKitToolArguments" {

    It "maps RequiresProject to the default 'Path' argument" {
        $item = @{ Label = 'X'; RequiresProject = $true; Script = 'x.ps1' }
        $args = ConvertTo-DevKitToolArguments -Item $item -Values @{ Path = 'C:\proj' }
        $args['Path'] | Should -Be 'C:\proj'
    }

    It "honors a custom ProjectArgName" {
        $item = @{ Label = 'X'; RequiresProject = $true; ProjectArgName = 'ProjectPath'; Script = 'x.ps1' }
        $args = ConvertTo-DevKitToolArguments -Item $item -Values @{ ProjectPath = 'C:\proj' }
        $args['ProjectPath'] | Should -Be 'C:\proj'
        $args.Contains('Path') | Should -BeFalse
    }

    It "throws when a required project path is missing" {
        $item = @{ Label = 'X'; RequiresProject = $true; Script = 'x.ps1' }
        { ConvertTo-DevKitToolArguments -Item $item -Values @{} } | Should -Throw
    }

    It "maps RequiresFile to the manifest's ParamName" {
        $item = @{ Label = 'X'; RequiresFile = @{ ParamName = 'EnvFile'; Filter = '*.env' }; Script = 'x.ps1' }
        $args = ConvertTo-DevKitToolArguments -Item $item -Values @{ EnvFile = 'C:\a\.env' }
        $args['EnvFile'] | Should -Be 'C:\a\.env'
    }

    It "parses Int prompts and enforces Min/Max" {
        $item = @{
            Label = 'X'; Script = 'x.ps1'
            Prompts = @(@{ Name = 'Port'; Type = 'Int'; Prompt = 'port'; Min = 1; Max = 65535; InvalidMessage = 'Invalid port number.' })
        }
        (ConvertTo-DevKitToolArguments -Item $item -Values @{ Port = '3000' })['Port'] | Should -Be 3000
        { ConvertTo-DevKitToolArguments -Item $item -Values @{ Port = '70000' } } | Should -Throw 'Invalid port number.'
        { ConvertTo-DevKitToolArguments -Item $item -Values @{ Port = '0' } } | Should -Throw 'Invalid port number.'
        { ConvertTo-DevKitToolArguments -Item $item -Values @{ Port = 'abc' } } | Should -Throw 'Invalid port number.'
    }

    It "adds a YesNo prompt only when true" {
        $item = @{
            Label = 'X'; Script = 'x.ps1'
            Prompts = @(@{ Name = 'Recurse'; Type = 'YesNo'; Prompt = 'recurse?' })
        }
        (ConvertTo-DevKitToolArguments -Item $item -Values @{ Recurse = $true })['Recurse'] | Should -BeTrue
        (ConvertTo-DevKitToolArguments -Item $item -Values @{ Recurse = $false }).Contains('Recurse') | Should -BeFalse
    }

    It "skips blank Optional prompts but rejects blank required ones" {
        $item = @{
            Label = 'X'; Script = 'x.ps1'
            Prompts = @(
                @{ Name = 'Note'; Type = 'String'; Prompt = 'note'; Optional = $true }
                @{ Name = 'Name'; Type = 'String'; Prompt = 'name' }
            )
        }
        $args = ConvertTo-DevKitToolArguments -Item $item -Values @{ Note = ''; Name = 'ok' }
        $args.Contains('Note') | Should -BeFalse
        { ConvertTo-DevKitToolArguments -Item $item -Values @{ Name = '' } } | Should -Throw
    }

    It "merges StaticArgs last so they win" {
        $item = @{
            Label = 'X'; Script = 'x.ps1'
            Prompts = @(@{ Name = 'Force'; Type = 'YesNo'; Prompt = 'force?' })
            StaticArgs = @{ Force = $true; InfoOnly = $true }
        }
        $args = ConvertTo-DevKitToolArguments -Item $item -Values @{ Force = $false }
        $args['Force'] | Should -BeTrue
        $args['InfoOnly'] | Should -BeTrue
    }
}

Describe "Get-DevKitGuiCatalog (against the real manifests)" {

    BeforeAll {
        $script:catalog = Get-DevKitGuiCatalog -RootPath $script:RepoRoot
    }

    It "loads all 7 tool categories in 3 groups" {
        $script:catalog.Count | Should -Be 3
        $moduleCount = ($script:catalog | ForEach-Object { $_.Modules.Count } | Measure-Object -Sum).Sum
        $moduleCount | Should -Be 7
    }

    It "every manifest item references a script that exists on disk" {
        foreach ($group in $script:catalog) {
            foreach ($module in $group.Modules) {
                foreach ($item in $module.Items) {
                    $item.Key | Should -Not -BeNullOrEmpty
                    $item.Label | Should -Not -BeNullOrEmpty
                    $item.Script | Should -Not -BeNullOrEmpty
                    Test-Path (Join-Path $module.FolderPath $item.Script) | Should -BeTrue -Because "$($module.Name) -> $($item.Label)"
                }
            }
        }
    }

    It "Search-DevKitGuiTools finds tools by label and help text" {
        # @() matters: without it a single hashtable result would report its
        # KEY count (3), not the number of matching tools.
        $hits = @(Search-DevKitGuiTools -Catalog $script:catalog -Keyword 'port')
        $hits.Count | Should -BeGreaterThan 0
        @($hits | Where-Object { $_.Item.Label -eq 'Scan Common Dev Ports' }).Count | Should -Be 1

        $none = @(Search-DevKitGuiTools -Catalog $script:catalog -Keyword 'zzz-no-such-tool-zzz')
        $none.Count | Should -Be 0
    }

    It "wifi manifest's Fast Mode entry carries its -Fast static switch" {
        $wifi = @($script:catalog | ForEach-Object { $_.Modules } | Where-Object { $_.Folder -eq 'wifi' })[0]
        $fast = @($wifi.Items | Where-Object { $_.StaticArgs -and $_.StaticArgs['Fast'] })
        $fast.Count | Should -Be 1
        # And the static args survive argument resolution (StaticArgs merge
        # last and win). WiFi-FastMode.ps1 deliberately does not DECLARE
        # -Fast - it absorbs it; see that script's header note.
        $rendered = ConvertTo-DevKitToolArguments -Item $fast[0] -Values @{}
        $rendered['Fast'] | Should -BeTrue
    }
}

Describe "Get-DevKitCatalogPayload loadErrors" {

    BeforeAll {
        # The payload builder lives in the dispatch layer (RpcMethods.ps1);
        # Get-DevKitGuiCatalog + Get-DevKitModule are already loaded above.
        $global:DevKitRpcMethodsLoaded = $false
        . (Join-Path $script:RepoRoot 'core\RpcMethods.ps1')
    }

    It "emits an empty loadErrors array alongside a populated modules array for a healthy catalog" {
        $payload = Get-DevKitCatalogPayload -RootPath $script:RepoRoot
        , $payload.loadErrors | Should -BeOfType [array]
        @($payload.loadErrors) | Should -Be @()
        @($payload.modules).Count | Should -BeGreaterThan 0
    }

    It "surfaces per-folder load errors instead of letting a category vanish silently" {
        $payload = Get-DevKitCatalogPayload -RootPath (Join-Path $TestDrive 'no-such-root')
        @($payload.modules) | Should -Be @()
        # All 7 category folders fail to load (missing manifest) -> one
        # recorded error each, prefixed with the folder name.
        @($payload.loadErrors).Count | Should -Be 7
        @($payload.loadErrors)[0] | Should -Match '^\[ports\] '
    }
}
