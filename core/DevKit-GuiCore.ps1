#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Pure-logic core for the DevKit desktop GUI - Northstar DevKit
.DESCRIPTION
    Dot-sourceable, UI-free functions backing gui/DevKit-GUI.ps1: loading the
    tool-category manifests (one per tools/ folder) as one catalog, searching it, and turning a
    manifest item plus resolved dialog values into a script argument table
    (the same rules the CLI applies in cli/src/catalog.rs).

    Everything here is deliberately free of WPF/console side effects so it
    can be covered by Pester (tests/Unit/GuiCore.Tests.ps1), matching the
    repo's "pure parsers/converters get unit tests" convention.

    Created by Northstar Software Development
    Website: https://www.northstarcoding.com
#>

# ==================== CATALOG ====================

function Get-DevKitGuiCategories {
    <#
    .SYNOPSIS
        Ordered category groups for the GUI's left navigation. Mirrors the
        Main Menu groupings hand-written in DevKit.ps1 (kept in sync manually,
        the same way Get-DevKitSearchableCategories is).
    #>
    return @(
        @{ Group = 'Development';                  Folders = @('ports', 'node', 'nextjs', 'vite') }
        @{ Group = 'Version Control & Containers'; Folders = @('git', 'docker') }
        @{ Group = 'Network';                      Folders = @('wifi') }
    )
}

function Get-DevKitGuiCatalog {
    <#
    .SYNOPSIS
        Loads every tool-category manifest (via Get-DevKitModule from
        tools/lib/DevKit-Common.ps1) into the GUI's grouped catalog structure.
    .PARAMETER RootPath
        The DevKit repo root (the folder containing the tools\ directory,
        which holds ports/, node/, ...).
    .OUTPUTS
        Array of @{ Group; Modules = @( <module hashtables, each carrying
        Folder/FolderPath plus the manifest's Name/Description/Items> ) }.
        A folder whose manifest is missing or broken is skipped, matching
        the TUI search's forgiving behavior. Any per-folder failure message
        is still collected into $global:DevKitCatalogLoadErrors (and
        written via Write-Verbose) so a total catalog-load failure is
        diagnosable instead of presenting a silently near-empty GUI.
    #>
    param([Parameter(Mandatory = $true)][string]$RootPath)

    $catalog = @()
    $global:DevKitCatalogLoadErrors = @()
    $toolsRoot = Join-Path $RootPath 'tools'
    foreach ($category in (Get-DevKitGuiCategories)) {
        $modules = @()
        foreach ($folder in $category.Folders) {
            $folderPath = Join-Path $toolsRoot $folder
            try {
                $module = Get-DevKitModule -FolderPath $folderPath
                $module.Folder = $folder
                $modules += $module
            } catch {
                $errorMessage = "[$folder] $($_.Exception.Message)"
                $global:DevKitCatalogLoadErrors += $errorMessage
                Write-Verbose "Get-DevKitGuiCatalog: skipped '$folder' - $errorMessage"
                continue
            }
        }
        if ($modules.Count -gt 0) {
            $catalog += @{ Group = $category.Group; Modules = $modules }
        }
    }
    return $catalog
}

function Search-DevKitGuiTools {
    <#
    .SYNOPSIS
        Case-insensitive keyword search over every catalog item's label and
        help text - the GUI equivalent of the TUI's '/' search.
    .OUTPUTS
        Array of @{ ModuleName; FolderPath; Item } for each match.
    #>
    param(
        [Parameter(Mandatory = $true)][array]$Catalog,
        [Parameter(Mandatory = $true)][string]$Keyword
    )

    $found = @()
    foreach ($group in $Catalog) {
        foreach ($module in $group.Modules) {
            foreach ($item in $module.Items) {
                $haystack = "$($module.Name) $($item.Label) $($item.Help)"
                if ($haystack -match [regex]::Escape($Keyword)) {
                    $found += @{
                        ModuleName = $module.Name
                        FolderPath = $module.FolderPath
                        Item       = $item
                    }
                }
            }
        }
    }
    return $found
}

# ==================== ARGUMENT RESOLUTION ====================

function ConvertTo-DevKitToolArguments {
    <#
    .SYNOPSIS
        Turns a manifest item plus the values collected from the GUI's
        dialogs into the argument hashtable splatted to the tool's script.
        The rules, shared with the CLI (build_arguments in cli/src/catalog.rs):
        RequiresProject uses ProjectArgName or 'Path'; a YesNo prompt only
        becomes an argument when true; missing non-optional prompt values are
        an error; StaticArgs merge last and win. The result is [ordered] so
        the rendered command line is deterministic (project/file first, then
        prompts in manifest order, then static args).
    .PARAMETER Item
        One entry from a module manifest's Items array.
    .PARAMETER Values
        Hashtable of already-resolved inputs keyed by parameter name: the
        project path under ProjectArgName/'Path', the file path under
        RequiresFile.ParamName, and one entry per Prompts spec under its Name.
    .OUTPUTS
        The (ordered) argument hashtable to splat.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Item,
        [hashtable]$Values = @{}
    )

    $callArgs = [ordered]@{}

    if ($Item.RequiresProject) {
        $argName = if ($Item.ProjectArgName) { $Item.ProjectArgName } else { 'Path' }
        $projectPath = $Values[$argName]
        if ([string]::IsNullOrWhiteSpace([string]$projectPath)) {
            throw "Missing required project path for '$($Item.Label)'."
        }
        $callArgs[$argName] = $projectPath
    } elseif ($Item.RequiresFile) {
        $paramName = $Item.RequiresFile.ParamName
        $filePath = $Values[$paramName]
        if ([string]::IsNullOrWhiteSpace([string]$filePath)) {
            throw "Missing required file for '$($Item.Label)'."
        }
        $callArgs[$paramName] = $filePath
    }

    if ($Item.Prompts) {
        foreach ($promptSpec in $Item.Prompts) {
            $value = $null
            if ($Values.ContainsKey($promptSpec.Name)) { $value = $Values[$promptSpec.Name] }

            if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
                if ($promptSpec.Optional) { continue }
                $msg = if ($promptSpec.InvalidMessage) { $promptSpec.InvalidMessage } else { "Invalid value for $($promptSpec.Name)." }
                throw $msg
            }

            if ($promptSpec.Type -eq 'Int') {
                $intValue = 0
                if (-not [int]::TryParse([string]$value, [ref]$intValue)) {
                    $msg = if ($promptSpec.InvalidMessage) { $promptSpec.InvalidMessage } else { "Invalid value for $($promptSpec.Name)." }
                    throw $msg
                }
                if (($promptSpec.ContainsKey('Min')) -and $null -ne $promptSpec.Min -and $intValue -lt [int]$promptSpec.Min) {
                    $msg = if ($promptSpec.InvalidMessage) { $promptSpec.InvalidMessage } else { "Invalid value for $($promptSpec.Name)." }
                    throw $msg
                }
                if (($promptSpec.ContainsKey('Max')) -and $null -ne $promptSpec.Max -and $intValue -gt [int]$promptSpec.Max) {
                    $msg = if ($promptSpec.InvalidMessage) { $promptSpec.InvalidMessage } else { "Invalid value for $($promptSpec.Name)." }
                    throw $msg
                }
                $value = $intValue
            }

            # YesNo only ever adds the arg when the answer is true - a false
            # answer means "leave the switch off", on every surface.
            if ($promptSpec.Type -eq 'YesNo' -and -not [bool]$value) { continue }
            if ($promptSpec.Type -eq 'YesNo') { $value = $true }

            $callArgs[$promptSpec.Name] = $value
        }
    }

    if ($Item.StaticArgs) {
        foreach ($key in $Item.StaticArgs.Keys) { $callArgs[$key] = $Item.StaticArgs[$key] }
    }

    return $callArgs
}
